<?php
/**
 * Plugin Name: Meu Deletador de Anexos S3 (com Logs de Debug)
 * Description: Deleta anexos do S3 quando são deletados do WordPress, com logs detalhados.
 * Version: 1.1-debug
 * Author: Seu Nome
 */

error_log("MEU_S3_DELETER_LOG: Script s3-hook-deleter.php (v1.1-debug) INICIADO em " . date("Y-m-d H:i:s"));

// Se o AWS SDK for carregado via Composer na raiz do WordPress
if (file_exists(ABSPATH . 'vendor/autoload.php')) {
    error_log("MEU_S3_DELETER_LOG: Tentando carregar vendor/autoload.php de ABSPATH.");
    require_once ABSPATH . 'vendor/autoload.php';
}
// Se o SDK estiver dentro do diretório deste plugin (se você o empacotar junto)
// elseif (file_exists(__DIR__ . '/vendor/autoload.php')) {
//    error_log("MEU_S3_DELETER_LOG: Tentando carregar vendor/autoload.php de __DIR__.");
//    require_once __DIR__ . '/vendor/autoload.php';
// }
// Adicione outras verificações de carregamento do SDK conforme necessário

use Aws\S3\S3Client;
use Aws\Exception\AwsException;

if (!defined('ABSPATH')) {
    error_log("MEU_S3_DELETER_LOG: Acesso direto ao script negado (ABSPATH não definido).");
    exit; // Acesso direto não permitido
}

// --- Configurações ---
// É melhor definir essas constantes no seu wp-config.php para segurança e flexibilidade
if (!defined('MEU_S3_BUCKET_NAME')) {
    // Esta linha abaixo é apenas para fallback caso não esteja no wp-config.php
    // O ideal é que 'MEU_S3_BUCKET_NAME' seja definido no wp-config.php pelo script de setup.
    define('MEU_S3_BUCKET_NAME', 'seu-bucket-s3-aqui'); // Substitua pelo nome do seu bucket
    error_log("MEU_S3_DELETER_LOG: AVISO - MEU_S3_BUCKET_NAME não estava definido, usando valor padrão de fallback.");
}
if (!defined('MEU_S3_REGION')) {
    define('MEU_S3_REGION', 'sua-regiao-s3-aqui'); // ex: 'us-east-1'
    error_log("MEU_S3_DELETER_LOG: AVISO - MEU_S3_REGION não estava definido, usando valor padrão de fallback.");
}
if (!defined('MEU_S3_BASE_PATH_IN_BUCKET')) {
    define('MEU_S3_BASE_PATH_IN_BUCKET', 'wp-content/uploads/');
    error_log("MEU_S3_DELETER_LOG: AVISO - MEU_S3_BASE_PATH_IN_BUCKET não estava definido, usando valor padrão de fallback.");
}
// --------------------


/**
 * Engancha na ação 'delete_attachment' para deletar arquivos do S3.
 */
add_action('delete_attachment', 'meu_plugin_handle_s3_attachment_deletion', 10, 1);
error_log("MEU_S3_DELETER_LOG: Hook 'delete_attachment' adicionado para 'meu_plugin_handle_s3_attachment_deletion'.");

/**
 * Lida com a deleção de um anexo e suas miniaturas do S3.
 *
 * @param int $post_id O ID do post do anexo que está sendo deletado.
 */
function meu_plugin_handle_s3_attachment_deletion($post_id) {
    error_log("MEU_S3_DELETER_LOG: Hook 'delete_attachment' DISPARADO para Post ID: " . $post_id);

    // Verifica se as constantes S3 estão definidas e não com valores padrão do plugin
    if (empty(MEU_S3_BUCKET_NAME) || MEU_S3_BUCKET_NAME === 'seu-bucket-s3-aqui') {
        error_log("MEU_S3_DELETER_LOG: Nome do bucket S3 (MEU_S3_BUCKET_NAME) não configurado corretamente ou usando valor padrão. Valor: '" . MEU_S3_BUCKET_NAME . "'. Post ID: " . $post_id);
        return;
    }
    if (empty(MEU_S3_REGION) || MEU_S3_REGION === 'sua-regiao-s3-aqui') {
        error_log("MEU_S3_DELETER_LOG: Região S3 (MEU_S3_REGION) não configurada corretamente ou usando valor padrão. Valor: '" . MEU_S3_REGION . "'. Post ID: " . $post_id);
        return;
    }
    error_log("MEU_S3_DELETER_LOG: Constantes S3 - Bucket: '" . MEU_S3_BUCKET_NAME . "', Região: '" . MEU_S3_REGION . "', Base Path: '" . MEU_S3_BASE_PATH_IN_BUCKET . "'");

    // Verifica se a classe do SDK AWS está carregada
    if (!class_exists('Aws\S3\S3Client')) {
        error_log("MEU_S3_DELETER_LOG: Classe SDK AWS 'Aws\\S3\\S3Client' NAO ENCONTRADA. Post ID: " . $post_id);
        if (file_exists(ABSPATH . 'vendor/autoload.php')) {
            error_log("MEU_S3_DELETER_LOG: Autoloader do Composer (ABSPATH . 'vendor/autoload.php') ENCONTRADO, mas a classe S3Client ainda não está disponível.");
        } else {
            error_log("MEU_S3_DELETER_LOG: Autoloader do Composer (ABSPATH . 'vendor/autoload.php') NAO ENCONTRADO.");
        }
        return;
    }
    error_log("MEU_S3_DELETER_LOG: Classe SDK AWS 'Aws\\S3\\S3Client' ENCONTRADA. Post ID: " . $post_id);

    $attachment_metadata = wp_get_attachment_metadata($post_id);
    // Usando json_encode para melhor visualização de arrays/objetos no log, limitando a profundidade
    error_log("MEU_S3_DELETER_LOG: Metadados do anexo para Post ID $post_id: " . json_encode($attachment_metadata, JSON_PRETTY_PRINT, 5));


    if (false === $attachment_metadata || !isset($attachment_metadata['file'])) {
        error_log("MEU_S3_DELETER_LOG: Metadados não encontrados ou chave 'file' ausente para o anexo ID: " . $post_id);
        return;
    }

    $s3_objects_to_delete = [];

    // Adiciona o arquivo original à lista de deleção
    // $attachment_metadata['file'] geralmente é algo como "2023/05/imagem.jpg"
    $s3_original_key = MEU_S3_BASE_PATH_IN_BUCKET . $attachment_metadata['file'];
    $s3_objects_to_delete[] = ['Key' => $s3_original_key];
    error_log("MEU_S3_DELETER_LOG: Chave S3 original para deletar: " . $s3_original_key);

    // Adiciona todas as miniaturas à lista de deleção
    if (isset($attachment_metadata['sizes']) && is_array($attachment_metadata['sizes'])) {
        $path_parts = pathinfo($attachment_metadata['file']);
        // O diretório base dentro da pasta de uploads (ex: "2023/05/")
        $base_dir_in_uploads = $path_parts['dirname'] ? trailingslashit($path_parts['dirname']) : '';

        foreach ($attachment_metadata['sizes'] as $size_name => $size_info) {
            if (isset($size_info['file'])) {
                $thumbnail_key = MEU_S3_BASE_PATH_IN_BUCKET . $base_dir_in_uploads . $size_info['file'];
                $s3_objects_to_delete[] = ['Key' => $thumbnail_key];
                error_log("MEU_S3_DELETER_LOG: Chave S3 de miniatura para deletar ($size_name): " . $thumbnail_key);
            }
        }
    }
    
    // Remove duplicatas, caso haja alguma sobreposição
    $s3_objects_to_delete = array_map("unserialize", array_unique(array_map("serialize", $s3_objects_to_delete)));
    error_log("MEU_S3_DELETER_LOG: Lista final de objetos S3 para deletar (Post ID $post_id): " . json_encode($s3_objects_to_delete));


    if (empty($s3_objects_to_delete)) {
        error_log("MEU_S3_DELETER_LOG: Nenhuma chave S3 para deletar foi identificada para o anexo ID: " . $post_id . ". Interrompendo.");
        return;
    }

    try {
        error_log("MEU_S3_DELETER_LOG: Tentando instanciar S3Client com região: " . MEU_S3_REGION);
        $s3Client = new S3Client([
            'region'  => MEU_S3_REGION,
            'version' => 'latest',
            // As credenciais devem vir da IAM Role da instância EC2
        ]);
        error_log("MEU_S3_DELETER_LOG: S3Client instanciado. Tentando deletar objetos do bucket '" . MEU_S3_BUCKET_NAME . "'...");

        $result = $s3Client->deleteObjects([
            'Bucket' => MEU_S3_BUCKET_NAME,
            'Delete' => [
                'Objects' => $s3_objects_to_delete,
                'Quiet'   => false, // Definir como true para não retornar erros se a chave não existir,
                                  // mas false é melhor para logging durante o desenvolvimento.
            ],
        ]);

        // Usando json_encode para melhor visualização de arrays/objetos no log, limitando a profundidade
        error_log("MEU_S3_DELETER_LOG: Resultado da operação deleteObjects (Post ID $post_id): " . json_encode($result->toArray(), JSON_PRETTY_PRINT, 5));


        $deleted_keys_log = [];
        if (isset($result['Deleted']) && !empty($result['Deleted'])) {
            foreach($result['Deleted'] as $deleted_item) {
                $deleted_keys_log[] = $deleted_item['Key'];
            }
            error_log("MEU_S3_DELETER_LOG: Objetos deletados do S3 com sucesso para o anexo ID {$post_id}: " . implode(', ', $deleted_keys_log));
        }


        if (isset($result['Errors']) && !empty($result['Errors'])) {
            foreach ($result['Errors'] as $error) {
                error_log("MEU_S3_DELETER_LOG: ERRO S3 ao deletar objeto '{$error['Key']}' (Post ID {$post_id}): Code={$error['Code']}, Message={$error['Message']}");
            }
        }

    } catch (AwsException $e) {
        error_log("MEU_S3_DELETER_LOG: EXCECAO AWS (Post ID $post_id): " . $e->getAwsErrorMessage() . " | Request ID: " . $e->getAwsRequestId() . " | HTTP Status Code: " . $e->getStatusCode() . " | AWS Error Code: " . $e->getAwsErrorCode() . " | AWS Error Type: " . $e->getAwsErrorType());
        // Para um log mais completo da exceção, mas pode ser muito verboso:
        // error_log("MEU_S3_DELETER_LOG: EXCECAO AWS COMPLETA (Post ID $post_id): " . print_r($e, true));
    } catch (Exception $e) {
        error_log("MEU_S3_DELETER_LOG: EXCECAO GERAL (Post ID $post_id): " . $e->getMessage() . " | Trace: " . $e->getTraceAsString());
    }
    error_log("MEU_S3_DELETER_LOG: Fim da execução de 'meu_plugin_handle_s3_attachment_deletion' para o Post ID: " . $post_id);
}

// Função para ajudar a logar no error_log do PHP, útil para debug
// Removida pois error_log() já faz o trabalho. A função write_log original foi mantida no seu script base.
// Se WP_DEBUG for usado, o error_log do PHP já é o destino padrão quando WP_DEBUG_LOG é true.

error_log("MEU_S3_DELETER_LOG: Script s3-hook-deleter.php (v1.1-debug) totalmente PROCESSADO.");
?>
