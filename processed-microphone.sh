TARGET_SOURCE="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ | awk -F'= ' '/node.name =/{gsub(/"/,"",$2); print $2; exit}')"
RAW_SKU="$(cat /sys/class/dmi/id/product_sku 2>/dev/null || true)"

case "$RAW_SKU" in
  F1|F1-A|F2)
    MIC_NAME="Detachable Microphone"
    ;;
  *)
    MIC_NAME="Internal Microphone"
    ;;
esac

if [ -z "$TARGET_SOURCE" ]; then
  echo "Could not find the current audio input. Please select the built-in microphone and try again."
  exit 1
fi

# Keep the real microphone input low enough to avoid clipping/noise.
wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 30%

mkdir -p ~/.config/pipewire/pipewire.conf.d

cat > ~/.config/pipewire/pipewire.conf.d/99-starlabs-mic-processing.conf <<EOF
context.modules = [
    { name = libpipewire-module-echo-cancel
        flags = [ ifexists nofail ]
        args = {
            aec.method = webrtc
            aec.args = {
                noise_suppression = true
                gain_control = true
                high_pass_filter = true
            }

            source.props = {
                node.name = "starlabs_mic_processed"
                node.description = "$MIC_NAME"
                media.class = "Audio/Source"
            }

            capture.props = {
                node.name = "starlabs_mic_capture"
                target.object = "$TARGET_SOURCE"
            }

            sink.props = {
                node.name = "starlabs_mic_sink"
                node.description = "$MIC_NAME Sink"
                media.class = "Audio/Sink"
            }

            playback.props = {
                node.name = "starlabs_mic_playback"
            }
        }
    }
]
EOF
