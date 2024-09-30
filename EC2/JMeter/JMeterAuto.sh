#!/bin/bash

# Defina suas variáveis
S3_BUCKET_NAME="seu-bucket-s3"
JMETER_TEST_PLAN="seu-plano-de-teste.jmx"
JMETER_RESULT_FILE="resultado-teste.jtl"

# Atualizar o sistema
sudo yum update -y

# Instalar Java (necessário para o JMeter)
sudo yum install java-1.8.0-openjdk -y

# Baixar e descompactar o JMeter (substitua pela versão desejada)
wget https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-5.4.1.tgz
tar -xzf apache-jmeter-5.4.1.tgz
rm apache-jmeter-5.4.1.tgz

# Navegar para a pasta do JMeter
cd apache-jmeter-5.4.1/bin/

# Baixar o plano de teste do S3
aws s3 cp s3://$S3_BUCKET_NAME/$JMETER_TEST_PLAN .

# Executar o plano de teste do JMeter
./jmeter -n -t $JMETER_TEST_PLAN -l $JMETER_RESULT_FILE

# Upload dos resultados para o S3
aws s3 cp $JMETER_RESULT_FILE s3://$S3_BUCKET_NAME/

# Opcional: desligar a instância após a conclusão do teste
# sudo shutdown -h now
