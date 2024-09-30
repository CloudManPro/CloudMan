# Configurações
$region = "us-east-1"
$repositoryName = "task-hub"
$imageTag = "latest"
$accountId = aws sts get-caller-identity --query "Account" --output text
$ecrUri = "$($accountId).dkr.ecr.$($region).amazonaws.com"
$awsProfile = "RBPM"  # Defina o nome do perfil da AWS

# Autenticação no ECR com o perfil RBPM
aws ecr get-login-password --region $region --profile $awsProfile | docker login --username AWS --password-stdin "$($ecrUri)"

# Construir a imagem
docker build -t $repositoryName .

# Marcar a imagem para o ECR
docker tag "${repositoryName}:latest" "$($ecrUri)/$($repositoryName):$($imageTag)"

# Enviar a imagem para o ECR
docker push "$($ecrUri)/$($repositoryName):$($imageTag)"

Write-Host "Imagem enviada para o ECR com sucesso."
