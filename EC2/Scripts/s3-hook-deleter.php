<?php
/**
 * Plugin Name: Meu Deletador de Anexos S3 (com Logs de Debug Avançado)
 * Description: Deleta anexos do S3 quando são deletados do WordPress, com logs detalhados.
 * Version: 1.2-debug-priority
 * Author: Seu Nome
 */

// Log inicial para garantir que o arquivo está sendo lido
error_log("MEU_S3_DELETER_LOG_V1.2: Script s3-hook-deleter.php (v1.2-debug-priority) INICIADO em " . date("Y-m-d H:i:s"));

// Tenta carregar o autoloader do Composer
if (file_exists(ABSPATH . 'vendor/autoload.php')) {
    error_log("MEU_S3_DELETER_LOG_V1.2: Tentando carregar vendor/autoload.php de ABSPATH.");
    require_once ABSPATH . 'vendor/autoload.php';
    error_log("MEU_S3_DELETER_LOG_V1.2: vendor/autoload.php de ABSPATH CARREGADO (ou tentativa feita).");
} else {
    error_log("MEU_S3_DELETER_LOG_V1.2: vendor/autoload.php de ABSPATH NAO ENCONTRADO.");
}

// Declaração de 'use' após o require_once
use Aws\S3\S3Client;
use Aws\Exception\AwsException;

// Verifica se o WordPress está definido
if (!defined('ABSPATH')) {
    error_log("MEU_S3_DELETER_LOG_V1.2: Acesso direto ao script negado (ABSPATH não definido). Saindo.");
    exit; // Acesso direto não permitido
}
error_log("MEU_S3_DELETER_LOG_V1.2: ABSPATH está definido. Prosseguindo.");

// --- Configurações ---
// Estas constantes DEVEM ser definidas no wp-config.php pelo seu script de setup.
// Os logs abaixo ajudarão a confirmar se elas foram carregadas corretamente.
if (!defined('MEU_S3_BUCKET_NAME')) {
    define('MEU_S3_BUCKET_NAME', 'fallback-bucket-nao-configurado');
    error_log("MEU_S3_DELETER_LOG_V1.2: AVISO CRÍTICO - MEU_S3_BUCKET_NAME não estava definido no wp-config.php! Usando valor de fallback: 'fallback-bucket-nao-configurado'. ISSO PRECISA SER CORRIGIDO.");
}
if (!defined('MEU_S3_REGION')) {
    define('MEU_S3_REGION', 'fallback-region-nao-configurada');
    error_log("MEU_S3_DELETER_LOG_V1.2: AVISO CRÍTICO - MEU_S3_REGION não estava definido no wp-config.php! Usando valor de fallback: 'fallback-region-nao-configurada'. ISSO PRECISA SER CORRIGIDO.");
}
if (!defined('MEU_S3_BASE_PATH_IN_BUCKET')) {
    define('MEU_S3_BASE_PATH_IN_BUCKET', 'wp-content/uploads/'); // Valor padrão razoável
    error_log("MEU_S3_DELETER_LOG_V1.2: AVISO - MEU_S3_BASE_PATH_IN_BUCKET não estava definido no wp-config.php. Usando valor de fallback: 'wp-content/uploads/'.");
}
error_log("MEU_S3_DELETER_LOG_V1.2: Constantes após verificação - Bucket: '" . MEU_S3_BUCKET_NAME . "', Região: '" . MEU_S3_REGION . "', Base Path: '" . MEU_S3_BASE_PATH_IN_BUCKET . "'");
// --------------------


/**
 * Engancha na ação 'delete_attachment' para deletar arquivos do S3.
 * Prioridade alterada para 1 para tentar executar antes de outros possíveis hooks.
 */
// Log ANTES de adicionar a ação
error_log("MEU_S3_DELETER_LOG_V1.2: PRESTES a adicionar o hook 'delete_attachment' para 'meu_plugin_handle_s3_attachment_deletion_v1_2' com prioridade 1.");

add_action('delete_attachment', 'meu_plugin_handle_s3_attachment_deletion_v1_2', 1, 1); // Prioridade 1, nome da função atualizado

// Log DEPOIS de adicionar a ação
error_log("MEU_S3_DELETER_LOG_V1.2: Hook 'delete_attachment' ADICIONADO para 'meu_plugin_handle_s3_attachment_deletion_v1_2' com prioridade 1.");


/**
 * Lida com a deleção de um anexo e suas miniaturas do S3.
 * Nome da função atualizado para corresponder ao add_action.
 *
 * @param int $post_id O ID do post do anexo que está sendo deletado.
 */
function meu_plugin_handle_s3_attachment_deletion_v1_2($post_id) { // Nome da função atualizado
    error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO DO HOOK 'meu_plugin_handle_s3_attachment_deletion_v1_2' DISPARADA! Post ID: " . $post_id);

    // Verifica se as constantes S3 estão definidas e não com valores de fallback do plugin
    if (empty(MEU_S3_BUCKET_NAME) || MEU_S3_BUCKET_NAME === 'fallback-bucket-nao-configurado' || MEU_S3_BUCKET_NAME === 'seu-bucket-s3-aqui') {
        error_log("MEU_S3_DELETER_LOG_V1.2: ERRO FATAL NA FUNCAO - Nome do bucket S3 (MEU_S3_BUCKET_NAME) não configurado corretamente. Valor: '" . MEU_S3_BUCKET_NAME . "'. Post ID: " . $post_id . ". Interrompendo.");
        return;
    }
    if (empty(MEU_S3_REGION) || MEU_S3_REGION === 'fallback-region-nao-configurada' || MEU_S3_REGION === 'sua-regiao-s3-aqui') {
        error_log("MEU_S3_DELETER_LOG_V1.2: ERRO FATAL NA FUNCAO - Região S3 (MEU_S3_REGION) não configurada corretamente. Valor: '" . MEU_S3_REGION . "'. Post ID: " . $post_id . ". Interrompendo.");
        return;
    }
    error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Constantes S3 verificadas OK - Bucket: '" . MEU_S3_BUCKET_NAME . "', Região: '" . MEU_S3_REGION . "'");

    // Verifica se a classe do SDK AWS está carregada
    if (!class_exists('Aws\S3\S3Client')) {
        error_log("MEU_S3_DELETER_LOG_V1.2: ERRO FATAL NA FUNCAO - Classe SDK AWS 'Aws\\S3\\S3Client' NAO ENCONTRADA. Post ID: " . $post_id . ". Interrompendo.");
        if (file_exists(ABSPATH . 'vendor/autoload.php')) {
            error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Autoloader do Composer (ABSPATH . 'vendor/autoload.php') ENCONTRADO, mas a classe S3Client ainda não está disponível.");
        } else {
            error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Autoloader do Composer (ABSPATH . 'vendor/autoload.php') NAO ENCONTRADO.");
        }
        return;
    }
    error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Classe SDK AWS 'Aws\\S3\\S3Client' ENCONTRADA. Post ID: " . $post_id);

    $attachment_metadata = wp_get_attachment_metadata($post_id);
    error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Metadados do anexo para Post ID $post_id: " . json_encode($attachment_metadata, JSON_PRETTY_PRINT, 3)); // Profundidade menor para logs mais curtos


    if (false === $attachment_metadata || !isset($attachment_metadata['file'])) {
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Metadados não encontrados ou chave 'file' ausente para o anexo ID: " . $post_id . ". Interrompendo.");
        return;
    }
    error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Chave 'file' dos metadados: '" . $attachment_metadata['file'] . "'");


    $s3_objects_to_delete = [];
    $s3_original_key = MEU_S3_BASE_PATH_IN_BUCKET . $attachment_metadata['file'];
    $s3_objects_to_delete[] = ['Key' => $s3_original_key];
    error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Chave S3 original para deletar: " . $s3_original_key);

    if (isset($attachment_metadata['sizes']) && is_array($attachment_metadata['sizes'])) {
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Encontradas " . count($attachment_metadata['sizes']) . " miniaturas nos metadados.");
        $path_parts = pathinfo($attachment_metadata['file']);
        $base_dir_in_uploads = $path_parts['dirname'] ? trailingslashit($path_parts['dirname']) : '';

        foreach ($attachment_metadata['sizes'] as $size_name => $size_info) {
            if (isset($size_info['file'])) {
                $thumbnail_key = MEU_S3_BASE_PATH_IN_BUCKET . $base_dir_in_uploads . $size_info['file'];
                $s3_objects_to_delete[] = ['Key' => $thumbnail_key];
                error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Chave S3 de miniatura para deletar ($size_name): " . $thumbnail_key);
            } else {
                error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Miniatura '$size_name' não tem a chave 'file' nos metadados.");
            }
        }
    } else {
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Nenhuma miniatura ('sizes') encontrada nos metadados.");
    }
    
    $s3_objects_to_delete = array_map("unserialize", array_unique(array_map("serialize", $s3_objects_to_delete)));
    error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Lista final de " . count($s3_objects_to_delete) . " objetos S3 para deletar (Post ID $post_id): " . json_encode($s3_objects_to_delete));


    if (empty($s3_objects_to_delete)) {
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Nenhuma chave S3 para deletar foi identificada para o anexo ID: " . $post_id . ". Interrompendo.");
        return;
    }

    try {
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - PRESTES a instanciar S3Client com região: '" . MEU_S3_REGION . "' e versão 'latest'.");
        $s3Client = new S3Client([
            'region'  => MEU_S3_REGION,
            'version' => 'latest',
        ]);
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - S3Client INSTANCIADO. PRESTES a deletar objetos do bucket '" . MEU_S3_BUCKET_NAME . "'...");

        $result = $s3Client->deleteObjects([
            'Bucket' => MEU_S3_BUCKET_NAME,
            'Delete' => [
                'Objects' => $s3_objects_to_delete,
                'Quiet'   => false,
            ],
        ]);
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - Resultado da operação deleteObjects (Post ID $post_id): " . json_encode($result->toArray(), JSON_PRETTY_PRINT, 3));

        $deleted_keys_log = [];
        if (isset($result['Deleted']) && !empty($result['Deleted'])) {
            foreach($result['Deleted'] as $deleted_item) {
                $deleted_keys_log[] = $deleted_item['Key'];
            }
            error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - SUCESSO S3: Objetos deletados do S3 para o anexo ID {$post_id}: " . implode(', ', $deleted_keys_log));
        }

        if (isset($result['Errors']) && !empty($result['Errors'])) {
            foreach ($result['Errors'] as $error) {
                error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - ERRO S3 ao deletar objeto '{$error['Key']}' (Post ID {$post_id}): Code={$error['Code']}, Message={$error['Message']}");
            }
        }

    } catch (AwsException $e) {
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - EXCECAO AWS (Post ID $post_id): " . $e->getAwsErrorMessage() . " | Request ID: " . $e->getAwsRequestId() . " | HTTP Status Code: " . $e->getStatusCode() . " | AWS Error Code: " . $e->getAwsErrorCode() . " | AWS Error Type: " . $e->getAwsErrorType());
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - EXCECAO AWS Trace: " . $e->getTraceAsString());
    } catch (Exception $e) {
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - EXCECAO GERAL (Post ID $post_id): " . $e->getMessage());
        error_log("MEU_S3_DELETER_LOG_V1.2: FUNCAO - EXCECAO GERAL Trace: " . $e->getTraceAsString());
    }
    error_log("MEU_S3_DELETER_LOG_V1.2: Fim da execução da FUNCAO 'meu_plugin_handle_s3_attachment_deletion_v1_2' para o Post ID: " . $post_id);
}

error_log("MEU_S3_DELETER_LOG_V1.2: Script s3-hook-deleter.php (v1.2-debug-priority) totalmente PROCESSADO e hooks registrados.");
?>
