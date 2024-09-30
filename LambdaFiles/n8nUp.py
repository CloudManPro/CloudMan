import boto3
import os
from time import sleep
import json
from operator import itemgetter
import time


# Obtém o nome do ASG das variáveis de ambiente
ASGName = os.getenv("aws_autoscaling_group_Target_Name_0")
Account = os.getenv("Account")
SSMName0 = os.getenv("aws_ssm_parameter_Source_Name_0")
SSMRegion0 = os.getenv("aws_ssm_parameter_Source_Region_0")
SSMName1 = os.getenv("aws_ssm_parameter_Source_Name_1")
LTName = os.getenv("aws_launch_template_Target_Name_0")
record_name = os.getenv("aws_route53_zone_Target_Name_0")


ssm_client = boto3.client('ssm', region_name=SSMRegion0)
route53_client = boto3.client('route53')
ec2_client = boto3.client('ec2')
asg_client = boto3.client('autoscaling')


try:
    response = ssm_client.get_parameter(Name=SSMName0, WithDecryption=True)
    value = response['Parameter']['Value']
    print("value", value)
    value_dict = json.loads(value)
    hosted_zone_id = value_dict['id']
    print("hosted_zone_id", hosted_zone_id)
except Exception as e:
    print(f"Erro ao obter o parâmetro {SSMName0}: {e}")

try:
    response = ssm_client.get_parameter(Name=SSMName1, WithDecryption=True)
    value = response['Parameter']['Value']
    print("value", value)
    value_dict = json.loads(value)
    launch_template_id = value_dict['id']
    print("launch_template_id", launch_template_id)
except Exception as e:
    print(f"Erro ao obter o parâmetro {SSMName1}: {e}")



def lambda_handler(event, context):

    # Passo 1: Encontrar o snapshot mais recente com a tag especificada
    snapshots = ec2_client.describe_snapshots(Filters=[
        {'Name': 'tag:Name', 'Values': [ASGName]},
        {'Name': 'owner-id', 'Values': [Account]}  # Garante que apenas snapshots do proprietário da conta sejam considerados
    ])['Snapshots']

    if not snapshots:
        print("Nenhum snapshot encontrado.")
    else:
        # Ordena os snapshots pela data de criação em ordem decrescente
        latest_snapshot = sorted(snapshots, key=itemgetter('StartTime'), reverse=True)[0]
        print(f"O snapshot mais recente é {latest_snapshot['SnapshotId']}")


    # Passo 2: Criar uma AMI a partir do snapshot mais recente com tag
    
    response = ec2_client.register_image(
        Name=f"{ASGName}-AMI-{latest_snapshot['StartTime'].strftime('%Y-%m-%d')}",
        Description=f"AMI criada a partir do snapshot {latest_snapshot['SnapshotId']}",
        Architecture='x86_64',  # Especifica a arquitetura da AMI como x86_64
        BlockDeviceMappings=[
            {
                'DeviceName': '/dev/sda1',
                'Ebs': {
                    'SnapshotId': latest_snapshot['SnapshotId'],
                    'DeleteOnTermination': True,
                    'VolumeSize': latest_snapshot.get('VolumeSize', 8),
                    'VolumeType': 'gp2',
                },
            },
        ],
        RootDeviceName='/dev/sda1',
        VirtualizationType='hvm',
    )
    ami_id = response['ImageId']
    print(f"AMI {ami_id} criada com sucesso a partir do snapshot {latest_snapshot['SnapshotId']}")
    # Aplicar tag à nova AMI
    ec2_client.create_tags(
        Resources=[ami_id],
        Tags=[{'Key': 'Name', 'Value': ASGName}]
    )
    print(f"Tag aplicada à AMI {ami_id}.")


    # Passo 3: Criar uma nova versão do Launch Template com a nova AMI
    lt_data = ec2_client.describe_launch_template_versions(
        LaunchTemplateId=launch_template_id,
        Versions=['$Latest']
    )
    latest_version_config = lt_data['LaunchTemplateVersions'][0]['LaunchTemplateData']
    latest_version_config['ImageId'] = ami_id
    
    response = ec2_client.create_launch_template_version(
        LaunchTemplateId=launch_template_id,
        LaunchTemplateData=latest_version_config,
        VersionDescription='Nova versão com AMI atualizada'
    )
    new_version_number = response['LaunchTemplateVersion']['VersionNumber']
    print(f"Nova versão do Launch Template criada: {new_version_number}, usando AMI: {ami_id}")
    
    # Passo 4: Definir a nova versão como padrão
    ec2_client.modify_launch_template(
        LaunchTemplateId=launch_template_id,
        DefaultVersion=str(new_version_number)
    )
    print(f"Versão {new_version_number} do Launch Template {launch_template_id} definida como padrão.")
    
    #********** Passo 4: Ativar o ASG
    try:
        response = asg_client.update_auto_scaling_group(
            AutoScalingGroupName=ASGName,
            MaxSize=1,
            MinSize=1,
            DesiredCapacity=1
        )
        print(f"ASG '{ASGName}' atualizado com sucesso para MaxSize=1, MinSize=1, DesiredCapacity=1.")
    except Exception as e:
        print(f"Erro ao atualizar o ASG '{ASGName}': {e}")
    
    #********** Passo 5: Deletar snapshots com tag do ASGName
    #Lista todos os snapshots com a tag específica
    snapshots = ec2_client.describe_snapshots(Filters=[
        {'Name': 'tag:Name', 'Values': [ASGName]}
    ])['Snapshots']
    # Lista todas as AMIs para verificar quais snapshots estão em uso
    images = ec2_client.describe_images(Owners=['self'])['Images']
    # Cria um conjunto de IDs de snapshots que estão em uso por AMIs
    used_snapshot_ids = set()
    for image in images:
        for block_device in image['BlockDeviceMappings']:
            if 'Ebs' in block_device and 'SnapshotId' in block_device['Ebs']:
                used_snapshot_ids.add(block_device['Ebs']['SnapshotId'])
    # Filtra os snapshots que não estão mais em uso
    unused_snapshots = [snapshot for snapshot in snapshots if snapshot['SnapshotId'] not in used_snapshot_ids]
    # Deleta os snapshots desvinculados
    for snapshot in unused_snapshots:
        try:
            ec2_client.delete_snapshot(SnapshotId=snapshot['SnapshotId'])
            print(f"Snapshot {snapshot['SnapshotId']} deletado com sucesso.")
        except Exception as e:
            print(f"Erro ao deletar o snapshot {snapshot['SnapshotId']}: {e}")
            
            
    #********** Passo6: Configurar Route53 com IP da EC2
    # Obtém a lista de instâncias EC2 associadas ao ASG
    WAIT_TIME_SECONDS = 10  # Tempo de espera entre as tentativas
    while True:
        response = asg_client.describe_auto_scaling_groups(AutoScalingGroupNames=[ASGName])
        asg = response.get('AutoScalingGroups', [])[0]
        # Filtra instâncias que estão em 'InService' (executando) ou 'Pending' (iniciando)
        instance_ids = [i['InstanceId'] for i in asg['Instances'] if i['LifecycleState'] in ('InService', 'Pending')]
        if instance_ids:
            # Assume a primeira instância para simplificar
            instance_id = instance_ids[0]
            ec2_response = ec2_client.describe_instances(InstanceIds=[instance_id])
            instance = ec2_response['Reservations'][0]['Instances'][0]
            # Verifica se o estado é 'running' ou 'pending' e se há um IP público
            if 'PublicIpAddress' in instance:
                public_ip = instance['PublicIpAddress']
                # Atualiza o registro DNS
                route53_client.change_resource_record_sets(
                    HostedZoneId=hosted_zone_id,
                    ChangeBatch={
                        'Changes': [{
                            'Action': 'UPSERT',
                            'ResourceRecordSet': {
                                'Name': record_name,
                                'Type': 'A',
                                'TTL': 300,
                                'ResourceRecords': [{'Value': public_ip}]
                            }
                        }]
                    }
                )
                break
        # Aguarda antes da próxima verificação
        time.sleep(WAIT_TIME_SECONDS)
    return {
            'statusCode': 200,
            'body': "Execução completa. Verifique os logs para o conteúdo do parâmetro."
        }
    

