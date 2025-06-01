<?php
/**
 * Plugin Name: Meu Deletador de Anexos S3
 * Description: Deleta anexos do S3 quando são deletados do WordPress.
 * Version: 1.0
 * Author: Seu Nome
 */

// Se o AWS SDK for carregado via Composer na raiz do WordPress
if (file_exists(ABSPATH . 'vendor/autoload.php')) {
    require_once ABSPATH . 'vendor/autoload.php';
}
// Se o SDK estiver dentro do diretório deste plugin (se você o empacotar junto)
// elseif (file_exists(__DIR__ . '/vendor/autoload.php')) {
//    require_once __DIR__ . '/vendor/autoload.php';
// }
// Adicione outras verificações de carregamento do SDK conforme necessário

use Aws\S3\S3Client;
use Aws\Exception\AwsException;

if (!defined('ABSPATH')) {
    exit; // Acesso direto não permitido
}

// --- Configurações ---
// É melhor definir essas constantes no seu wp-config.php para segurança e flexibilidade
if (!defined('MEU_S3_BUCKET_NAME')) {
    define('MEU_S3_BUCKET_NAME', 'seu-bucket-s3-aqui'); // Substitua pelo nome do seu bucket
}
if (!defined('MEU_S3_REGION')) {
    define('MEU_S3_REGION', 'sua-regiao-s3-aqui'); // ex: 'us-east-1'
}
// Opcional: Se os seus uploads no S3 não estiverem diretamente em 'wp-content/uploads/'
if (!defined('MEU_S3_BASE_PATH_IN_BUCKET')) {
    define('MEU_S3_BASE_PATH_IN_BUCKET', 'wp-content/uploads/');
}
// --------------------


/**
 * Engancha na ação 'delete_attachment' para deletar arquivos do S3.
 */
add_action('delete_attachment', 'meu_plugin_handle_s3_attachment_deletion', 10, 1);

/**
 * Lida com a deleção de um anexo e suas miniaturas do S3.
 *
 * @param int $post_id O ID do post do anexo que está sendo deletado.
 */
function meu_plugin_handle_s3_attachment_deletion($post_id) {
    if (empty(MEU_S3_BUCKET_NAME) || MEU_S3_BUCKET_NAME === 'seu-bucket-s3-aqui') {
        error_log("MEU_S3_DELETER: Nome do bucket S3 não configurado. Post ID: " . $post_id);
        return;
    }
    if (empty(MEU_S3_REGION) || MEU_S3_REGION === 'sua-regiao-s3-aqui') {
        error_log("MEU_S3_DELETER: Região S3 não configurada. Post ID: " . $post_id);
        return;
    }

    // Verifica se o AWS SDK está carregado
    if (!class_exists('Aws\S3\S3Client')) {
        error_log("MEU_S3_DELETER: AWS SDK para PHP não parece estar carregado. Post ID: " . $post_id);
        return;
    }

    $attachment_metadata = wp_get_attachment_metadata($post_id);

    if (false === $attachment_metadata || !isset($attachment_metadata['file'])) {
        error_log("MEU_S3_DELETER: Metadados não encontrados ou arquivo principal não definido para o anexo ID: " . $post_id);
        return;
    }

    $s3_objects_to_delete = [];

    // Adiciona o arquivo original à lista de deleção
    // $attachment_metadata['file'] geralmente é algo como "2023/05/imagem.jpg"
    $s3_original_key = MEU_S3_BASE_PATH_IN_BUCKET . $attachment_metadata['file'];
    $s3_objects_to_delete[] = ['Key' => $s3_original_key];

    // Adiciona todas as miniaturas à lista de deleção
    if (isset($attachment_metadata['sizes']) && is_array($attachment_metadata['sizes'])) {
        $path_parts = pathinfo($attachment_metadata['file']);
        // O diretório base dentro da pasta de uploads (ex: "2023/05/")
        $base_dir_in_uploads = $path_parts['dirname'] ? trailingslashit($path_parts['dirname']) : '';

        foreach ($attachment_metadata['sizes'] as $size_name => $size_info) {
            if (isset($size_info['file'])) {
                $thumbnail_key = MEU_S3_BASE_PATH_IN_BUCKET . $base_dir_in_uploads . $size_info['file'];
                $s3_objects_to_delete[] = ['Key' => $thumbnail_key];
            }
        }
    }
    
    // Remove duplicatas, caso haja alguma sobreposição (improvável com a lógica acima, mas seguro)
    $s3_objects_to_delete = array_map("unserialize", array_unique(array_map("serialize", $s3_objects_to_delete)));


    if (empty($s3_objects_to_delete)) {
        error_log("MEU_S3_DELETER: Nenhuma chave S3 para deletar foi identificada para o anexo ID: " . $post_id);
        return;
    }

    try {
        $s3Client = new S3Client([
            'region'  => MEU_S3_REGION,
            'version' => 'latest',
            // As credenciais devem vir da IAM Role da instância EC2
        ]);

        $result = $s3Client->deleteObjects([
            'Bucket' => MEU_S3_BUCKET_NAME,
            'Delete' => [
                'Objects' => $s3_objects_to_delete,
                'Quiet'   => false, // Definir como true para não retornar erros se a chave não existir,
                                  // mas false é melhor para logging durante o desenvolvimento.
            ],
        ]);

        $deleted_keys_log = [];
        if (isset($result['Deleted']) && !empty($result['Deleted'])) {
            foreach($result['Deleted'] as $deleted_item) {
                $deleted_keys_log[] = $deleted_item['Key'];
            }
            error_log("MEU_S3_DELETER: Objetos deletados do S3 com sucesso para o anexo ID {$post_id}: " . implode(', ', $deleted_keys_log));
        }


        if (isset($result['Errors']) && !empty($result['Errors'])) {
            foreach ($result['Errors'] as $error) {
                error_log("MEU_S3_DELETER: Erro ao deletar objeto S3 '{$error['Key']}' para o anexo ID {$post_id}: Code={$error['Code']}, Message={$error['Message']}");
            }
        }

    } catch (AwsException $e) {
        error_log("MEU_S3_DELETER: Exceção AWS ao tentar deletar do S3 para o anexo ID {$post_id}: " . $e->getAwsErrorMessage() . " | Request ID: " . $e->getAwsRequestId());
    } catch (Exception $e) {
        error_log("MEU_S3_DELETER: Exceção geral ao tentar deletar do S3 para o anexo ID {$post_id}: " . $e->getMessage());
    }
}

// Função para ajudar a logar no error_log do PHP, útil para debug
if (!function_exists('write_log')) {
    function write_log($log) {
        if (true === WP_DEBUG) {
            if (is_array($log) || is_object($log)) {
                error_log(print_r($log, true));
            } else {
                error_log($log);
            }
        }
    }
}
