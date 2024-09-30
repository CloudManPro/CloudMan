import boto3
import os
from time import sleep

# Obtém o nome do ASG das variáveis de ambiente
ASGName = os.getenv("aws_autoscaling_group_Target_Name_0")
ec2_client = boto3.client('ec2')
asg_client = boto3.client('autoscaling')


def lambda_handler(event, context):
    
    # Passo 1: Filtra instâncias que estão no estado 'InService' no ASG
    response = asg_client.describe_auto_scaling_groups(AutoScalingGroupNames=[ASGName])
    instances = response['AutoScalingGroups'][0]['Instances']
    active_instance_ids = [instance['InstanceId'] for instance in instances if instance['LifecycleState'] == 'InService']
    
    # Itera sobre cada instância ativa
    for instance_id in active_instance_ids:
        # Passo 2: Obter o ID do volume do disco raiz da instância
        instance_details = ec2_client.describe_instances(InstanceIds=[instance_id])
        root_device = instance_details['Reservations'][0]['Instances'][0]['BlockDeviceMappings'][0]
        volume_id = root_device['Ebs']['VolumeId']
    
    #********** Passo 3: Criar snapshot do volume
    snapshot = ec2_client.create_snapshot(VolumeId=volume_id, Description=f"Backup antes de terminar {instance_id}")
    snapshot_id = snapshot['SnapshotId']
    print(f"Snapshot {snapshot_id} iniciado para o volume {volume_id} da instância {instance_id}")
    
    #********** Passo 4: Aplicar tag ao snapshot
    ec2_client.create_tags(Resources=[snapshot_id], Tags=[{'Key': 'Name', 'Value': ASGName}])
    print(f"Tag {ASGName} aplicada ao snapshot {snapshot_id}.")
    
    #********** Passo 5: Aguardar a conclusão do snapshot
    waiter = ec2_client.get_waiter('snapshot_completed')
    waiter.wait(SnapshotIds=[snapshot_id])
    print(f"Snapshot {snapshot_id} concluído.")
    
    #********** Passo 6: Desativar o ASG
    try:
        response = asg_client.update_auto_scaling_group(
            AutoScalingGroupName=ASGName,
            MaxSize=0,
            MinSize=0,
            DesiredCapacity=0
        )
        print(f"ASG '{ASGName}' atualizado com sucesso para MaxSize=0, MinSize=0, DesiredCapacity=0.")
    except Exception as e:
        print(f"Erro ao atualizar o ASG '{ASGName}': {e}")
    
    
    #********** Passo 7: Terminar Instâncias
    response = asg_client.describe_auto_scaling_groups(AutoScalingGroupNames=[ASGName])
    instances = response['AutoScalingGroups'][0]['Instances']
    # Filtra instâncias que estão no estado 'InService' no ASG
    active_instance_ids = [instance['InstanceId'] for instance in instances if instance['LifecycleState'] == 'InService']
    if active_instance_ids:
        print(f"Instâncias ativas no ASG '{ASGName}': {active_instance_ids}")
        for instance_id in active_instance_ids:
            # Verifica se a instância está no estado 'running'
            desc = ec2_client.describe_instances(InstanceIds=[instance_id])
            state = desc['Reservations'][0]['Instances'][0]['State']['Name']
            ec2_client.terminate_instances(InstanceIds=[instance_id])
            desc = ec2_client.describe_instances(InstanceIds=[instance_id])
            state = desc['Reservations'][0]['Instances'][0]['State']['Name']
            if state == 'running':
                # Termina a instância após a conclusão do snapshot
                ec2_client.terminate_instances(InstanceIds=[instance_id])
                print(f"Instância {instance_id} terminada.")
    else:
        print(f"Nenhuma instância ativa encontrada no ASG '{ASGName}' para terminar.")
        
    #********** Passo 8: desanexar e deregistar a AMI
    amis = ec2_client.describe_images(Filters=[{'Name': 'tag:Name', 'Values': [ASGName]}])
    for ami in amis['Images']:
        ami_id = ami['ImageId']
        print(f"Desanexando AMI {ami_id}")
        ec2_client.deregister_image(ImageId=ami_id)
        # Passo 8.1: Deletar o Snapshot Associado
        for block_device in ami['BlockDeviceMappings']:
            if 'Ebs' in block_device:
                snapshot_id = block_device['Ebs']['SnapshotId']
                print(f"Deletando Snapshot {snapshot_id}")
                ec2_client.delete_snapshot(SnapshotId=snapshot_id)
    
    return {
            'statusCode': 200,
            'body': "Execução completa. Verifique os logs para o conteúdo do parâmetro."
        }
    

