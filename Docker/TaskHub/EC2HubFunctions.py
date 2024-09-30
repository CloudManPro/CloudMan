# Importações
from fastapi import FastAPI, Request
import dns.resolver
import boto3
import json
import os
import logging
import watchtower
import datetime
from dotenv import load_dotenv
import asyncio
from concurrent.futures import ThreadPoolExecutor
from threading import Semaphore
from threading import Lock
import requests
# Carregar as variáveis de ambiente do arquivo .env e habilitar o patch automático
load_dotenv()
XRay = os.getenv('XRay_Enabled',"False")
if XRay == "True":
    XRayEnabled = True
    from aws_xray_sdk.core import xray_recorder
    from aws_xray_sdk.core import patch_all
    patch_all()
else:
    XRayEnabled = False

def LogMessage(Msg):
    if StatusLogsEnabled:
        logger.info(Msg)

# Função para listar todos os serviços em um namespace
def list_services_in_namespace(client, namespace_id):
    services = []
    paginator = client.get_paginator('list_services')
    for page in paginator.paginate(Filters=[{'Name': 'NAMESPACE_ID', 'Values': [namespace_id]}]):
        services.extend(page['Services'])
    return services


# Função para encontrar o ID de um namespace pelo nome
def find_namespace_id_by_name(client, namespace_name):
    paginator = client.get_paginator('list_namespaces')
    for page in paginator.paginate():
        for ns in page['Namespaces']:
            if ns['Name'] == namespace_name:
                return ns['Id']
    return None

# Função para listar instâncias de um serviço
def list_instances_of_service(client, service_id):
    instances = []
    paginator = client.get_paginator('list_instances')
    for page in paginator.paginate(ServiceId=service_id):
        instances.extend(page['Instances'])
    return instances

#Função que resolve DNS SRV
def resolve_srv_record(service_name):
    try:
        answers = dns.resolver.resolve(service_name, 'SRV')
        for rdata in answers:
            return str(rdata.target).rstrip('.'), rdata.port
    except Exception as e:
        LogMessage(f"Erro ao resolver SRV para {service_name}: {e}")
        return None, None