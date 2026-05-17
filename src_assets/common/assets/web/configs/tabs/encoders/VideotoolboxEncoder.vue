<script setup>
import { ref } from 'vue'
import Checkbox from "../../../Checkbox.vue";

const props = defineProps([
  'platform',
  'config',
])

const config = ref(props.config)
</script>

<template>
  <div id="videotoolbox-encoder" class="config-page">
    <template v-if="platform === 'macos'">
      <div class="mb-3">
        <label for="hevc_mode" class="form-label">GameStream Codec Support</label>
        <select id="hevc_mode" class="form-select" v-model="config.hevc_mode">
          <option value="0">Automatic</option>
          <option value="1">H.264 Only</option>
          <option value="2">H.264 + HEVC (H.265)</option>
          <option value="3">H.264 + HEVC Main10 (HDR)</option>
        </select>
        <div class="form-text">
          Current GameStream sessions still negotiate H.264 or HEVC with the client. This controls what Lumen advertises to compatibility clients.
        </div>
      </div>
      <div class="mb-3">
        <label for="macos_bridge_codec" class="form-label">Lumen Bridge Default Codec</label>
        <select id="macos_bridge_codec" class="form-select" v-model="config.macos_bridge_codec">
          <option value="h264">H.264</option>
          <option value="hevc">HEVC (H.265)</option>
          <option value="prores-proxy">ProRes Proxy (Experimental)</option>
        </select>
        <div class="form-text">
          This only affects Lumen-native bridge/manual macOS capture defaults. It does not change the GameStream transport codec path.
        </div>
      </div>
    </template>
    <template v-else>
      <div class="mb-3">
        <label for="vt_coder" class="form-label">{{ $t('config.vt_coder') }}</label>
        <select id="vt_coder" class="form-select" v-model="config.vt_coder">
          <option value="auto">{{ $t('config.ffmpeg_auto') }}</option>
          <option value="cabac">{{ $t('config.coder_cabac') }}</option>
          <option value="cavlc">{{ $t('config.coder_cavlc') }}</option>
        </select>
      </div>
      <div class="mb-3">
        <label for="vt_software" class="form-label">{{ $t('config.vt_software') }}</label>
        <select id="vt_software" class="form-select" v-model="config.vt_software">
          <option value="auto">{{ $t('_common.auto') }}</option>
          <option value="disabled">{{ $t('_common.disabled') }}</option>
          <option value="allowed">{{ $t('config.vt_software_allowed') }}</option>
          <option value="forced">{{ $t('config.vt_software_forced') }}</option>
        </select>
      </div>
      <Checkbox class="mb-3"
                id="vt_realtime"
                desc=""
                locale-prefix="config"
                v-model="config.vt_realtime"
                default="true"
      ></Checkbox>
    </template>
  </div>
</template>

<style scoped>

</style>
