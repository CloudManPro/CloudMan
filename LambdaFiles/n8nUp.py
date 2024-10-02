import boto3
import os
from time import sleep
import json
from operator import itemgetter
import time

# Obtém o nome do ASG das variáveis de ambiente
ASG_NAME = os.getenv("AWS_AUTOSCALING_GROUP_TARGET_NAME_0")
ACCOUNT = os.getenv("ACCOUNT")
SSM_NAME_0 = os.getenv("AWS_SSM_PARAMETER_SOURCE_NAME_0")
SSM_REGION_0 = os.getenv("AWS_SSM_PARAMETER_SOURCE_REGION_0")
SSM_NAME_1 = os.getenv("AWS_SSM_PARAMETER_SOURCE_NAME_1")
LT_NAME = os.getenv("AWS_LAUNCH_TEMPLATE_TARGET_NAME_0")
RECORD_NAME = os.getenv("AWS_ROUTE53_ZONE_TARGET_NAME_0")

ssm_client = boto3.client('ssm', region_name=SSM_REGION_0)
route53_client = boto3.client('route53')
ec2_client = boto3.client('ec2')
asg_client = boto3.client('autoscaling')

try:
    response = ssm_client.get_parameter(Name=SSM_NAME_0, WithDecryption=True)
    value = response['Parameter']['Value']
    print("value", value)
    value_dict = json.loads(value)
    hosted_zone_id = value_dict['id']
    print("hosted_zone_id", hosted_zone_id)
except Exception as e:
    print(f"Erro ao obter o parâmetro {SSM_NAME_0}: {e}")

try:
    response = ssm_client.get_parameter(Name=SSM_NAME_1, WithDecryption=True)
    value = response['Parameter']['Value']
    print("value", value)
    value_dict = json.loads(value)
    launch_template_id = value_dict['id']
    print("launch_template_id", launch_template_id)
except Exception as e:
    print(f"Erro ao obter o parâmetro {SSM_NAME_1}: {e}")


def lambda_handler(event, context):
    # Passo 1: Encontrar o snapshot mais recente com a tag especificada
    snapshots = ec2_client.describe_snapshots(Filters=[
        {'Name': 'tag:Name', 'Values': [ASG_NAME]},
        # Garante que apenas snapshots do proprietário da conta sejam considerados
        {'Name': 'owner-id', 'Values': [ACCOUNT]}
    ])['Snapshots']

    if not snapshots:
        print("Nenhum snapshot encontrado.")
    else:
        # Ordena os snapshots pela data de criação em ordem decrescente
        latest_snapshot = sorted(
            snapshots, key=itemgetter('StartTime'), reverse=True)[0]
        print(f"O snapshot mais recente é {latest_snapshot['SnapshotId']}")

    # Passo 2: Criar uma AMI a partir do snapshot mais recente com tag
    response = ec2_client.register_image(
        Name=f"{ASG_NAME}-AMI-{latest_snapshot['StartTime'].strftime('%Y-%m-%d')}",
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
    print(
        f"AMI {ami_id} criada com sucesso a partir do snapshot {latest_snapshot['SnapshotId']}")

    # Aplicar tag à nova AMI
    ec2_client.create_tags(
        Resources=[ami_id],
        Tags=[{'Key': 'Name', 'Value': ASG_NAME}]
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
    print(
        f"Nova versão do Launch Template criada: {new_version_number}, usando AMI: {ami_id}")

    # Passo 4: Definir a nova versão como padrão
    ec2_client.modify_launch_template(
        LaunchTemplateId=launch_template_id,
        DefaultVersion=str(new_version_number)
    )
    print(
        f"Versão {new_version_number} do Launch Template {launch_template_id} definida como padrão.")

    # Passo 4: Ativar o ASG
    try:
        response = asg_client.update_auto_scaling_group(
            AutoScalingGroupName=ASG_NAME,
            MaxSize=1,
            MinSize=1,
            DesiredCapacity=1
        )
        print(
            f"ASG '{ASG_NAME}' atualizado com sucesso para MaxSize=1, MinSize=1, DesiredCapacity=1.")
    except Exception as e:
        print(f"Erro ao atualizar o ASG '{ASG_NAME}': {e}")

    # Passo 5: Deletar snapshots com tag do ASG_NAME
    snapshots = ec2_client.describe_snapshots(Filters=[
        {'Name': 'tag:Name', 'Values': [ASG_NAME]}
    ])['Snapshots']

    images = ec2_client.describe_images(Owners=['self'])['Images']
    used_snapshot_ids = set()
    for image in images:
        for block_device in image['BlockDeviceMappings']:
            if 'Ebs' in block_device and 'SnapshotId' in block_device['Ebs']:
                used_snapshot_ids.add(block_device['Ebs']['SnapshotId'])

    unused_snapshots = [
        snapshot for snapshot in snapshots if snapshot['SnapshotId'] not in used_snapshot_ids]

    for snapshot in unused_snapshots:
        try:
            ec2_client.delete_snapshot(SnapshotId=snapshot['SnapshotId'])
            print(f"Snapshot {snapshot['SnapshotId']} deletado com sucesso.")
        except Exception as e:
            print(f"Erro ao deletar o snapshot {snapshot['SnapshotId']}: {e}")

    # Passo 6: Configurar Route53 com IP da EC2
    WAIT_TIME_SECONDS = 10  # Tempo de espera entre as tentativas
    while True:
        response = asg_client.describe_auto_scaling_groups(
            AutoScalingGroupNames=[ASG_NAME])
        asg = response.get('AutoScalingGroups', [])[0]
        instance_ids = [i['InstanceId'] for i in asg['Instances']
                        if i['LifecycleState'] in ('InService', 'Pending')]
        if instance_ids:
            instance_id = instance_ids[0]
            ec2_response = ec2_client.describe_instances(
                InstanceIds=[instance_id])
            instance = ec2_response['Reservations'][0]['Instances'][0]
            if 'PublicIpAddress' in instance:
                public_ip = instance['PublicIpAddress']
                route53_client.change_resource_record_sets(
                    HostedZoneId=hosted_zone_id,
                    ChangeBatch={
                        'Changes': [{
                            'Action': 'UPSERT',
                            'ResourceRecordSet': {
                                'Name': RECORD_NAME,
                                'Type': 'A',
                                'TTL': 300,
                                'ResourceRecords': [{'Value': public_ip}]
                            }
                        }]
                    }
                )
                break
        time.sleep(WAIT_TIME_SECONDS)

    return {
        'statusCode': 200,
        'body': "Execução completa. Verifique os logs para o conteúdo do parâmetro."
    }
