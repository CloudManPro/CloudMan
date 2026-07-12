import json
import boto3
import csv
import io
import os
import gzip
import re
import urllib.parse
from decimal import Decimal, InvalidOperation
from datetime import datetime, timedelta, timezone

# --- Constantes e Configuração ---
RESOURCE_TAG_KEY = os.environ.get('RESOURCE_TAG_KEY', 'resourceTags/user:Name')
COST_COLUMN = 'lineItem/UnblendedCost'
PRODUCT_COLUMN = 'lineItem/ProductCode'
USAGE_TYPE_COLUMN = 'lineItem/UsageType'
USAGE_START_DATE_COLUMN = 'lineItem/UsageStartDate'
USAGE_ACCOUNT_COLUMN = 'lineItem/UsageAccountId'

# BUG CORRIGIDO (custo de IPv4 público perdido em "Untagged"): a AWS cobra
# endereços IPv4 públicos sob o produto "AmazonVPC", ligado ao ENI/EIP que
# efetivamente carrega o IP -- não ao recurso que "usa" esse IP (ex. um ALB).
# Essa linha de custo quase nunca vem com a cost-allocation tag do recurso
# dono, então sempre caía em "Untagged" e se perdia. O CUR já é gerado com
# `additional_schema_elements = ["RESOURCES"]` (ver Terraform), então a
# coluna abaixo já existe no CSV -- só não estava sendo lida.
RESOURCE_ID_COLUMN = 'lineItem/ResourceId'
UNTAGGABLE_PRODUCT_CODE = 'AmazonVPC'
UNTAGGABLE_USAGE_TYPE_PATTERN = 'PublicIPv4'

CUR_BUCKET_NAME_FALLBACK = os.environ.get('AWS_S3_BUCKET_NAME_0') or os.environ.get('AWS_S3_BUCKET_TARGET_NAME_0')
CONSOLIDATED_BUCKET_NAME = os.environ.get('AWS_S3_BUCKET_TARGET_NAME_0') or CUR_BUCKET_NAME_FALLBACK
CONSOLIDATED_KEY = os.getenv("CONSOLIDATED_KEY", "consolidated-costs/daily_costs_by_tag.json")

# Alterado padrão de retenção diária para 60 dias (para comportar a comparação de 30 dias anteriores)
DAYS_TO_RETAIN_ENV = os.getenv("DAYS_TO_RETAIN", "60")
MONTHS_TO_RETAIN_ENV = os.getenv("MONTHS_TO_RETAIN", "24")

try:
    DAYS_TO_RETAIN = int(DAYS_TO_RETAIN_ENV)
    if DAYS_TO_RETAIN <= 0:
        DAYS_TO_RETAIN = 60
except ValueError:
    DAYS_TO_RETAIN = 60

try:
    MONTHS_TO_RETAIN = int(MONTHS_TO_RETAIN_ENV)
    if MONTHS_TO_RETAIN <= 0:
        MONTHS_TO_RETAIN = 24
except ValueError:
    MONTHS_TO_RETAIN = 24

s3_client = boto3.client('s3')
# Novos clientes -- só leitura (Describe*), usados exclusivamente pra
# resolver o dono real de um ENI/EIP não tagueado (ver resolve_untagged_resource_name).
ec2_client = boto3.client('ec2')
elbv2_client = boto3.client('elbv2')

def decimal_default(obj):
    if isinstance(obj, Decimal): return str(obj)
    raise TypeError(f"Object of type {obj.__class__.__name__} is not JSON serializable")

def load_consolidated_data(bucket, key):
    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        print(f"Successfully loaded existing consolidated file from s3://{bucket}/{key}")
        data = json.loads(content)

        # --- Compatibilidade e Migração Retroativa ---
        if "costs_by_tag_and_date" in data:
            print("Migrating deprecated 'costs_by_tag_and_date' structure to split layout.")
            data["daily_costs"] = data.pop("costs_by_tag_and_date")

        if "daily_costs" not in data:
            data["daily_costs"] = {}
        if "monthly_costs" not in data:
            data["monthly_costs"] = {}
        # NOVO: índice secundário por resourceId (ARN/ENI/EIP), só populado
        # pra linhas SEM tag de custo -- ver process_single_csv_file. Permite
        # o frontend achar custo real de recursos importados que nunca
        # ganharam a cost-allocation tag na AWS, casando pelo ARN salvo no
        # próprio nó em vez da tag.
        if "resources_by_id" not in data:
            data["resources_by_id"] = {}

        return data
    except s3_client.exceptions.NoSuchKey:
        print(f"Consolidated file not found at s3://{bucket}/{key}. Initializing new structure.")
        return {
            "metadata": {
                "description": f"Daily costs (last {DAYS_TO_RETAIN} days) and monthly costs (last {MONTHS_TO_RETAIN} months) aggregated by tag '{RESOURCE_TAG_KEY}'.",
                "tag_key_used": RESOURCE_TAG_KEY,
                "days_retained": DAYS_TO_RETAIN,
                "months_retained": MONTHS_TO_RETAIN,
                "last_processed_cur_date": None,
                "last_processed_assembly_id": None,
                "last_updated_timestamp_utc": None,
                "currency_code": None
            },
            "daily_costs": {},
            "monthly_costs": {},
            "resources_by_id": {}
        }
    except Exception as e:
        print(f"ERROR: Failed to load consolidated data from s3://{bucket}/{key}. Error: {e}")
        raise

def save_consolidated_data(bucket, key, data):
    try:
        json_string = json.dumps(data, indent=2, default=decimal_default)
        s3_client.put_object(Bucket=bucket, Key=key, Body=json_string.encode('utf-8'), ContentType='application/json')
        print(f"Successfully saved updated consolidated file to s3://{bucket}/{key}")
    except Exception as e:
        print(f"ERROR: Failed to save consolidated data to s3://{bucket}/{key}. Error: {e}")
        raise

def read_manifest_file(bucket, key):
    try:
        print(f"Reading manifest file: s3://{bucket}/{key}")
        response = s3_client.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        return json.loads(content)
    except Exception as e:
        print(f"ERROR: Failed to read manifest file: {e}")
        raise


def _get_name_tag(tags):
    """Extrai a tag 'Name' de uma lista de tags no formato [{'Key':..,'Value':..}, ...]
    (formato comum a EC2/ELBv2/NAT Gateway). Retorna None se não achar."""
    for t in (tags or []):
        if t.get('Key') == 'Name':
            return t.get('Value')
    return None


def _resolve_via_eni(eni_id):
    """Resolve a tag 'Name' do recurso DONO de um ENI (eni-...) sem tag
    própria no CUR -- caso típico de IP público de EC2 ou de um Load
    Balancer (o ALB/NLB não expõe um ENI "seu" diretamente pro usuário,
    mas a AWS gerencia ENIs internos com uma Description identificável)."""
    resp = ec2_client.describe_network_interfaces(NetworkInterfaceIds=[eni_id])
    interfaces = resp.get('NetworkInterfaces', [])
    if not interfaces:
        return None
    eni = interfaces[0]

    # Caso 1: ENI pertence diretamente a uma instância EC2 (IP público
    # atribuído à própria instância) -- pega a tag Name da instância.
    instance_id = eni.get('Attachment', {}).get('InstanceId')
    if instance_id:
        tags_resp = ec2_client.describe_tags(
            Filters=[
                {'Name': 'resource-id', 'Values': [instance_id]},
                {'Name': 'key', 'Values': ['Name']}
            ]
        )
        for t in tags_resp.get('Tags', []):
            if t.get('Key') == 'Name':
                return t.get('Value')
        return None

    # Caso 2: ENI gerenciado por um Load Balancer -- a Description vem no
    # formato "ELB app/<lb-name>/<id>" (ALB) ou "ELB net/<lb-name>/<id>" (NLB).
    # NOTA: <lb-name> aqui é o nome "cru" do recurso na AWS, que pode não
    # bater com a tag lógica ("Name") usada no resto do app -- por isso
    # resolvemos o ARN e buscamos a tag Name de verdade, em vez de usar o
    # nome cru direto.
    description = eni.get('Description', '')
    match = re.search(r'ELB (?:app|net)/([^/]+)/', description)
    if match:
        lb_name = match.group(1)
        try:
            lb_resp = elbv2_client.describe_load_balancers(Names=[lb_name])
            lbs = lb_resp.get('LoadBalancers', [])
            if lbs:
                lb_arn = lbs[0]['LoadBalancerArn']
                tags_resp = elbv2_client.describe_tags(ResourceArns=[lb_arn])
                for td in tags_resp.get('TagDescriptions', []):
                    name = _get_name_tag(td.get('Tags'))
                    if name:
                        return name
        except Exception as e:
            print(f"WARN: Falha ao resolver Load Balancer '{lb_name}' a partir do ENI '{eni_id}': {e}")

    return None


def _resolve_via_eip(allocation_id):
    """Resolve a tag 'Name' do recurso DONO de um Elastic IP (eipalloc-...)
    sem tag própria -- caso típico do IP público de um NAT Gateway."""
    resp = ec2_client.describe_addresses(AllocationIds=[allocation_id])
    addresses = resp.get('Addresses', [])
    if not addresses:
        return None
    address = addresses[0]

    # Caso mais comum: EIP associado a um NAT Gateway.
    network_interface_id = address.get('NetworkInterfaceId')
    if network_interface_id:
        nat_resp = ec2_client.describe_nat_gateways(
            Filter=[{'Name': 'network-interface-id', 'Values': [network_interface_id]}]
        )
        for nat in nat_resp.get('NatGateways', []):
            name = _get_name_tag(nat.get('Tags'))
            if name:
                return name

    # Fallback: a própria EIP pode estar tagueada diretamente.
    return _get_name_tag(address.get('Tags'))


def resolve_untagged_resource_name(resource_id, cache):
    """Tenta descobrir a tag 'Name' do recurso DONO de um resourceId de rede
    (ENI ou EIP) que não veio com tag própria no CUR -- caso típico do IPv4
    público, cobrado sob AmazonVPC mas usado por outro recurso (ALB, NAT
    Gateway, EC2). Retorna None se não conseguir resolver -- nesse caso a
    linha cai em "Untagged", exatamente o comportamento de antes desta
    correção (nunca quebra o processamento por causa disso).

    `cache` é um dict compartilhado entre TODOS os arquivos CSV de um mesmo
    manifesto -- o mesmo ENI/EIP costuma se repetir em várias linhas/dias,
    evita bater na API da AWS de novo pro mesmo resourceId."""
    if resource_id in cache:
        return cache[resource_id]

    resolved_name = None
    try:
        if resource_id.startswith('eni-'):
            resolved_name = _resolve_via_eni(resource_id)
        elif resource_id.startswith('eipalloc-'):
            resolved_name = _resolve_via_eip(resource_id)
    except Exception as e:
        print(f"WARN: Falha ao resolver resourceId '{resource_id}': {e}")

    cache[resource_id] = resolved_name
    return resolved_name


def _accumulate_cost_entry(target_dict, key_value, usage_date, product_code, usage_key, cost):
    """Soma `cost` na estrutura padrão `{key_value: {date: {TotalUnblendedCost,
    CostsByProduct}}}`, criando os níveis que faltarem. Compartilhado entre o
    índice por TAG e o índice novo por resourceId -- mesmo formato, evita
    duplicar a lógica de acumulação duas vezes."""
    if key_value not in target_dict:
        target_dict[key_value] = {}
    if usage_date not in target_dict[key_value]:
        target_dict[key_value][usage_date] = {
            "TotalUnblendedCost": Decimal('0.0'),
            "CostsByProduct": {}
        }

    target_dict[key_value][usage_date]['TotalUnblendedCost'] += cost

    costs_by_product = target_dict[key_value][usage_date]['CostsByProduct']
    if product_code not in costs_by_product:
        costs_by_product[product_code] = {}
    costs_by_usage = costs_by_product[product_code]
    if usage_key not in costs_by_usage:
        costs_by_usage[usage_key] = Decimal('0.0')
    costs_by_usage[usage_key] += cost


def process_single_csv_file(bucket_name, object_key, fallback_date, resource_name_cache):
    daily_costs_by_tag = {}
    # NOVO: índice secundário por resourceId, só preenchido pra linhas que
    # ficam SEM tag (ver loop abaixo) -- ver comentário em load_consolidated_data.
    daily_costs_by_resource_id = {}
    currency_code = None
    body = None
    text_stream = None

    print(f"Processing data part: s3://{bucket_name}/{object_key}")

    try:
        s3_object = s3_client.get_object(Bucket=bucket_name, Key=object_key)
        body = s3_object['Body']
        is_gzipped = object_key.lower().endswith('.gz')

        if is_gzipped:
            gzip_stream = gzip.GzipFile(fileobj=body)
            text_stream = io.TextIOWrapper(gzip_stream, encoding='utf-8', errors='replace')
        else:
            text_stream = io.TextIOWrapper(body, encoding='utf-8', errors='replace')

        csv_reader = csv.DictReader(text_stream)
        processed_rows = 0
        currency_found = False

        for row in csv_reader:
            processed_rows += 1

            if not currency_found and processed_rows <= 10:
                currency_code_found = row.get('lineItem/CurrencyCode', row.get('pricing/currency'))
                if currency_code_found:
                    currency_code = currency_code_found
                    currency_found = True

            raw_usage_date = row.get(USAGE_START_DATE_COLUMN)
            if raw_usage_date and len(raw_usage_date) >= 10:
                usage_date = raw_usage_date[:10]
            else:
                usage_date = fallback_date or "UnknownDate"

            product_code = row.get(PRODUCT_COLUMN) or 'UnknownProduct'
            usage_type = row.get(USAGE_TYPE_COLUMN) or 'UnknownUsageType'
            # Lido incondicionalmente (não só no caso do IPv4) -- precisa
            # estar disponível pro índice novo por resourceId logo abaixo,
            # pra QUALQUER linha que acabe sem tag, não só a de IPv4.
            resource_id = row.get(RESOURCE_ID_COLUMN)

            tag_value = row.get(RESOURCE_TAG_KEY)
            if not tag_value:
                # BUG CORRIGIDO: custo de IPv4 público (cobrado sob AmazonVPC,
                # ligado ao ENI/EIP, não ao recurso que o usa) sempre caía
                # aqui em "Untagged" -- perdido pra sempre, mesmo sendo custo
                # real do ALB/NAT/EC2 dono do IP. Resolve o dono via API da
                # AWS, processado perto do dia real (preserva o histórico com
                # muito mais precisão do que reconstruir depois a partir da
                # config atual do recurso).
                if (
                    resource_id
                    and product_code == UNTAGGABLE_PRODUCT_CODE
                    and UNTAGGABLE_USAGE_TYPE_PATTERN in usage_type
                ):
                    resolved_name = resolve_untagged_resource_name(resource_id, resource_name_cache)
                    tag_value = resolved_name or "Untagged"
                else:
                    tag_value = "Untagged"

            cost_str = row.get(COST_COLUMN)
            try:
                cost = Decimal(cost_str) if cost_str else Decimal('0.0')
            except (InvalidOperation, TypeError):
                cost = Decimal('0.0')

            if cost == Decimal('0.0'):
                continue

            # Captura a conta ativa correspondente ao uso
            active_account = row.get(USAGE_ACCOUNT_COLUMN) or 'UnknownAccount'
            usage_key = f"{usage_type}@{active_account}"

            _accumulate_cost_entry(daily_costs_by_tag, tag_value, usage_date, product_code, usage_key, cost)

            # NOVO: linha ainda SEM tag (recurso importado sem cost-allocation
            # tag na AWS, ou resolução de IPv4 acima não achou dono) mas COM
            # resourceId -- indexa também por resourceId, pro frontend poder
            # casar pelo ARN salvo no nó quando a busca por tag falhar.
            if tag_value == "Untagged" and resource_id:
                _accumulate_cost_entry(
                    daily_costs_by_resource_id, resource_id, usage_date, product_code, usage_key, cost
                )

        print(f"Finished parsing part. Total rows scanned: {processed_rows}.")
        return daily_costs_by_tag, daily_costs_by_resource_id, currency_code

    except Exception as e:
        print(f"Error parsing file part {object_key}: {e}")
        return {}, {}, None
    finally:
        if text_stream and not text_stream.closed:
            try: text_stream.close()
            except Exception: pass
        if body and hasattr(body, 'close') and not body.closed:
             try: body.close()
             except Exception: pass

def merge_batch_into_temp(temp_dict, csv_costs, touched_months):
    """Mescla o lote de UM arquivo CSV (`csv_costs`, no formato
    `{key: {date: {...}}}`) no acumulador temporário do manifesto inteiro.
    Compartilhada entre o índice por TAG e o índice novo por resourceId --
    mesma lógica de mesclagem, só o dicionário-alvo muda."""
    for key_value, dates_dict in csv_costs.items():
        if key_value not in temp_dict:
            temp_dict[key_value] = {}
        for d_str, day_data in dates_dict.items():
            touched_months.add(d_str[:7])  # Captura formato YYYY-MM
            if d_str not in temp_dict[key_value]:
                temp_dict[key_value][d_str] = day_data
            else:
                existing_total = temp_dict[key_value][d_str]["TotalUnblendedCost"]
                new_total = day_data["TotalUnblendedCost"]
                temp_dict[key_value][d_str]["TotalUnblendedCost"] = existing_total + new_total

                for prod_code, prod_data in day_data["CostsByProduct"].items():
                    if prod_code not in temp_dict[key_value][d_str]["CostsByProduct"]:
                        temp_dict[key_value][d_str]["CostsByProduct"][prod_code] = prod_data
                    else:
                        for usage_type, cost_val in prod_data.items():
                            existing_val = temp_dict[key_value][d_str]["CostsByProduct"][prod_code].get(usage_type, Decimal('0.0'))
                            temp_dict[key_value][d_str]["CostsByProduct"][prod_code][usage_type] = existing_val + cost_val


def prune_daily_structure(consolidated_data, structure_key, cutoff_date):
    """Remove datas mais velhas que `cutoff_date` de
    `consolidated_data[structure_key]` (formato `{key: {date: {...}}}`),
    removendo também chaves que ficarem vazias. Compartilhada entre
    `daily_costs` (por tag) e `resources_by_id` (novo, por resourceId) --
    mesma janela de retenção de 60 dias pros dois. Retorna quantas datas
    foram removidas."""
    removed_count = 0
    empty_keys = []

    for key_value in list(consolidated_data[structure_key].keys()):
        dates_to_delete = []
        date_data = consolidated_data[structure_key][key_value]

        for date_str in date_data.keys():
            try:
                data_date = datetime.strptime(date_str, '%Y-%m-%d').date()
                if data_date < cutoff_date:
                    dates_to_delete.append(date_str)
            except ValueError:
                continue

        for date_to_delete in dates_to_delete:
            del consolidated_data[structure_key][key_value][date_to_delete]
            removed_count += 1

        if not consolidated_data[structure_key][key_value]:
            empty_keys.append(key_value)

    for key_to_delete in empty_keys:
        del consolidated_data[structure_key][key_to_delete]

    return removed_count


def rebuild_monthly_costs(consolidated_data, touched_months):
    """
    Sincroniza os custos mensais agregados com base nos dados diários.
    Garante que não haverá duplicidade ao reprocessar os dados do mês corrente.
    """
    daily = consolidated_data.get("daily_costs", {})
    monthly = consolidated_data.setdefault("monthly_costs", {})

    for tag_value, dates_dict in daily.items():
        tag_monthly = monthly.setdefault(tag_value, {})
        for month_str in touched_months:
            # Filtra os registros diários pertencentes ao mês afetado
            month_dates = {d: val for d, val in dates_dict.items() if d.startswith(month_str)}
            if not month_dates:
                # Se não existem mais dados diários na janela de retenção de 60 dias,
                # não sobrescrevemos o histórico do mês consolidado do passado
                continue

            total_unblended = Decimal('0.0')
            products = {}

            for d_str, day_data in month_dates.items():
                cost_val = day_data.get("TotalUnblendedCost", "0.0")
                total_unblended += Decimal(str(cost_val))

                for prod_code, prod_data in day_data.get("CostsByProduct", {}).items():
                    prod_entry = products.setdefault(prod_code, {})
                    for usage_type, cost_str in prod_data.items():
                        prod_entry[usage_type] = prod_entry.get(usage_type, Decimal('0.0')) + Decimal(str(cost_str))

            # Atualiza/Insere o mês consolidado com valores normalizados em string
            tag_monthly[month_str] = {
                "TotalUnblendedCost": str(total_unblended),
                "CostsByProduct": {
                    p: {ut: str(c) for ut, c in ut_dict.items()}
                    for p, ut_dict in products.items()
                }
            }

def lambda_handler(event, context):
    print(f"Lambda execution started. Received event: {json.dumps(event)}")

    manifest_key = None
    cur_bucket_name = None

    try:
        if 'Records' in event and isinstance(event['Records'], list) and event['Records'] and 's3' in event['Records'][0]:
            s3_event = event['Records'][0]['s3']
            cur_bucket_name = s3_event['bucket']['name']
            manifest_key = urllib.parse.unquote_plus(s3_event['object']['key'], encoding='utf-8')
        elif isinstance(event, dict) and 'object_key' in event:
            manifest_key = event['object_key']
            if CUR_BUCKET_NAME_FALLBACK:
                cur_bucket_name = CUR_BUCKET_NAME_FALLBACK
            else:
                return {'statusCode': 500, 'body': 'Configuration Error: Fallback bucket env var missing.'}
        else:
            return {'statusCode': 400, 'body': 'Invalid event structure.'}
    except Exception as e:
         return {'statusCode': 400, 'body': f'Error parsing S3 event: {str(e)}'}

    consolidated_bucket = CONSOLIDATED_BUCKET_NAME
    if not consolidated_bucket:
        return {'statusCode': 500, 'body': 'Configuration Error: Target bucket env var missing.'}

    # 1. Carregar arquivo de Manifesto (.json)
    try:
        manifest = read_manifest_file(cur_bucket_name, manifest_key)
    except Exception as e:
        return {'statusCode': 500, 'body': f'Failed to parse manifest: {str(e)}'}

    assembly_id = manifest.get("assemblyId", "UnknownAssembly")
    report_keys = manifest.get("reportKeys", [])

    # Captura o ID da conta pagadora do manifesto
    payer_account_id = manifest.get("payerAccountId", "UnknownAccount")


    if not report_keys:
        print("WARNING: No report keys to process inside the manifest.")
        return {'statusCode': 200, 'body': 'No report keys found.'}

    processing_date_str = None
    match = re.search(r'(\d{8})T\d{6}Z', assembly_id)
    if match:
        try:
            processing_date_str = datetime.strptime(match.group(1), '%Y%m%d').strftime('%Y-%m-%d')
        except ValueError:
            pass

    # 2. Processar e agrupar novos dados diários em lote
    temp_aggregated_costs = {}
    # NOVO: acumulador temporário do índice por resourceId (só linhas sem tag).
    temp_aggregated_resource_costs = {}
    final_currency_code = None
    touched_months = set()
    # Compartilhado entre TODOS os arquivos CSV deste manifesto -- ver
    # resolve_untagged_resource_name.
    resource_name_cache = {}

    for csv_key in report_keys:
        csv_costs, csv_resource_costs, csv_currency = process_single_csv_file(
            cur_bucket_name, csv_key, processing_date_str, resource_name_cache
        )
        if csv_currency:
            final_currency_code = csv_currency

        merge_batch_into_temp(temp_aggregated_costs, csv_costs, touched_months)
        # NOVO: mesmo tratamento pro índice por resourceId -- usa um `set()`
        # descartável pra `touched_months` porque essa estrutura não tem
        # agregação mensal própria (só o índice por tag tem).
        merge_batch_into_temp(temp_aggregated_resource_costs, csv_resource_costs, set())

    # Serializar decimais temporários para float/string
    daily_costs_data = json.loads(json.dumps(temp_aggregated_costs, default=decimal_default))
    resource_costs_data = json.loads(json.dumps(temp_aggregated_resource_costs, default=decimal_default))

    # 3. Carregar dados consolidados existentes do S3
    try:
        consolidated_data = load_consolidated_data(consolidated_bucket, CONSOLIDATED_KEY)
    except Exception as e:
        return {'statusCode': 500, 'body': f'Failed to load consolidated data: {str(e)}'}

    # 4. Mesclar novos dados na estrutura "daily_costs"
    daily_key = 'daily_costs'
    updated_tags_count = 0
    for tag_value, dates_dict in daily_costs_data.items():
        if tag_value not in consolidated_data[daily_key]:
            consolidated_data[daily_key][tag_value] = {}
        for date_str, day_data in dates_dict.items():
            consolidated_data[daily_key][tag_value][date_str] = day_data
        updated_tags_count += 1

    # NOVO: mesma mesclagem pro índice novo "resources_by_id".
    resources_key = 'resources_by_id'
    for resource_id_value, dates_dict in resource_costs_data.items():
        if resource_id_value not in consolidated_data[resources_key]:
            consolidated_data[resources_key][resource_id_value] = {}
        for date_str, day_data in dates_dict.items():
            consolidated_data[resources_key][resource_id_value][date_str] = day_data

    # 5. Sincronizar custos agregados mensais dos meses afetados
    rebuild_monthly_costs(consolidated_data, touched_months)
    print(f"Rebuilt monthly consolidated buckets for months: {list(touched_months)}")

    # 6. Obter data mais recente do dataset para determinar corte das podas
    all_dates = []
    for tag_val, dates_dict in consolidated_data[daily_key].items():
        for d_str in dates_dict.keys():
            try:
                all_dates.append(datetime.strptime(d_str, '%Y-%m-%d').date())
            except ValueError:
                continue

    if all_dates:
        reference_date = max(all_dates)
        print(f"Reference date determined for pruning: {reference_date}")
    else:
        reference_date = datetime.now(timezone.utc).date()
        print(f"Reference date falling back to current date: {reference_date}")

    # 7. Podar dados diários antigos (Mais velhos que 60 dias) -- mesma janela
    # aplicada aos dois índices (por tag e, agora, por resourceId).
    print(f"Starting pruning of daily data older than {DAYS_TO_RETAIN} days...")
    cutoff_date = reference_date - timedelta(days=DAYS_TO_RETAIN)
    dates_removed_count = prune_daily_structure(consolidated_data, daily_key, cutoff_date)
    resource_dates_removed_count = prune_daily_structure(consolidated_data, resources_key, cutoff_date)
    print(f"Pruned {dates_removed_count} daily_costs entries and {resource_dates_removed_count} resources_by_id entries.")

    # 8. Podar dados mensais consolidados antigos (Mais velhos que 24 meses)
    monthly_key = 'monthly_costs'
    months_removed_count = 0

    # Calcular limite de corte de 24 meses atrás baseado na referência
    ref_year = reference_date.year
    ref_month = reference_date.month
    cutoff_year = ref_year - (MONTHS_TO_RETAIN // 12)
    cutoff_month = ref_month - (MONTHS_TO_RETAIN % 12)
    if cutoff_month <= 0:
        cutoff_month += 12
        cutoff_year -= 1
    cutoff_month_str = f"{cutoff_year:04d}-{cutoff_month:02d}"

    print(f"Starting pruning of monthly aggregates older than {cutoff_month_str}...")

    if monthly_key in consolidated_data:
        for tag_value in list(consolidated_data[monthly_key].keys()):
            months_to_delete = []
            for m_str in consolidated_data[monthly_key][tag_value].keys():
                if m_str < cutoff_month_str:
                    months_to_delete.append(m_str)

            for m_to_delete in months_to_delete:
                del consolidated_data[monthly_key][tag_value][m_to_delete]
                months_removed_count += 1

            if not consolidated_data[monthly_key][tag_value]:
                del consolidated_data[monthly_key][tag_value]

    # Atualizar Metadados Globais do JSON
    consolidated_data['metadata']['last_processed_cur_date'] = processing_date_str
    consolidated_data['metadata']['last_processed_assembly_id'] = assembly_id
    consolidated_data['metadata']['last_updated_timestamp_utc'] = datetime.now(timezone.utc).isoformat(timespec='seconds') + 'Z'
    consolidated_data['metadata']['days_retained'] = DAYS_TO_RETAIN
    consolidated_data['metadata']['months_retained'] = MONTHS_TO_RETAIN
    if final_currency_code:
        consolidated_data['metadata']['currency_code'] = final_currency_code

    # Salvar o JSON Consolidado Final
    try:
        save_consolidated_data(consolidated_bucket, CONSOLIDATED_KEY, consolidated_data)
    except Exception as e:
        return {'statusCode': 500, 'body': f'Failed to save: {str(e)}'}

    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Consolidated cost data updated successfully.',
            'tags_updated': updated_tags_count,
            'resource_ids_updated': len(resource_costs_data),
            'daily_dates_removed': dates_removed_count,
            'resource_dates_removed': resource_dates_removed_count,
            'monthly_records_removed': months_removed_count
        })
    }