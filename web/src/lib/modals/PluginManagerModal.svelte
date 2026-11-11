<script lang="ts">
  import { authManager } from '#lib/managers/auth-manager.svelte.ts';
  import { pluginManager } from '#lib/managers/plugin-manager.svelte.ts';
  import { executeMutation, queryClient } from '#lib/queries/client.ts';
  import { installPluginMutation, searchPluginsQuery, uninstallPluginMutation } from '#lib/queries/plugin.query.ts';
  import type { PluginResponseDto } from '@immich/sdk';
  import { Badge, Button, Icon, IconButton, LoadingSpinner, Modal, ModalBody, Text } from '@immich/ui';
  import { mdiDeleteOutline, mdiPuzzleOutline, mdiUpload } from '@mdi/js';
  import { createQuery } from '@tanstack/svelte-query';
  import { t } from 'svelte-i18n';

  type Props = {
    onClose: () => void;
  };

  const { onClose }: Props = $props();

  const CORE_PLUGIN_NAME = 'immich-plugin-core';

  const query = createQuery(searchPluginsQuery, () => queryClient);
  const plugins = $derived(query.data ?? []);
  const isAdmin = $derived(authManager.authenticated && authManager.user.isAdmin);

  let fileInput = $state<HTMLInputElement>();
  let isInstalling = $state(false);

  const onFileSelected = async () => {
    const file = fileInput?.files?.[0];
    if (!fileInput || !file) {
      return;
    }

    fileInput.value = '';
    isInstalling = true;
    try {
      await executeMutation(installPluginMutation, [{ pluginUploadDto: { file } }], {
        onSuccess: () => void pluginManager.refresh(),
      });
    } finally {
      isInstalling = false;
    }
  };

  const onUninstall = (plugin: PluginResponseDto) =>
    executeMutation(uninstallPluginMutation, [{ id: plugin.id }], {
      confirm: {
        title: $t('uninstall_plugin'),
        prompt: $t('uninstall_plugin_confirmation', { values: { name: plugin.title } }),
        confirmText: $t('uninstall_plugin'),
      },
      onSuccess: () => void pluginManager.refresh(),
    });
</script>

<Modal title={$t('plugins')} {onClose} size="medium">
  <ModalBody>
    <div class="flex flex-col gap-4">
      <Text size="small" color="muted">{$t('plugins_help_text')}</Text>

      {#if isAdmin}
        <input
          bind:this={fileInput}
          type="file"
          accept=".zip,application/zip"
          class="hidden"
          onchange={onFileSelected}
        />
        <Button leadingIcon={mdiUpload} fullWidth loading={isInstalling} onclick={() => fileInput?.click()}>
          {$t('install_plugin_from_file')}
        </Button>
      {/if}

      {#if query.isPending}
        <div class="flex justify-center p-4"><LoadingSpinner /></div>
      {:else}
        <div class="flex flex-col gap-2">
          {#each plugins as plugin (plugin.id)}
            <div class="flex items-center gap-3 rounded-xl border border-gray-200 p-3 dark:border-gray-800">
              <div
                class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-immich-primary/10 text-immich-primary dark:bg-immich-dark-primary/15 dark:text-immich-dark-primary"
              >
                <Icon icon={mdiPuzzleOutline} size="18" />
              </div>
              <div class="min-w-0 grow">
                <div class="flex items-center gap-2">
                  <Text fontWeight="medium" class="truncate">{plugin.title}</Text>
                  <Badge size="small" color="secondary">v{plugin.version}</Badge>
                  {#if plugin.name === CORE_PLUGIN_NAME}
                    <Badge size="small">{$t('built_in')}</Badge>
                  {/if}
                </div>
                <Text size="tiny" color="muted" class="truncate">{plugin.description}</Text>
                <Text size="tiny" color="muted">
                  {plugin.author} · {$t('plugin_method_count', { values: { count: plugin.methods.length } })}
                </Text>
              </div>
              {#if isAdmin && plugin.name !== CORE_PLUGIN_NAME}
                <IconButton
                  icon={mdiDeleteOutline}
                  color="danger"
                  variant="ghost"
                  shape="round"
                  aria-label={$t('uninstall_plugin')}
                  onclick={() => onUninstall(plugin)}
                />
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  </ModalBody>
</Modal>
