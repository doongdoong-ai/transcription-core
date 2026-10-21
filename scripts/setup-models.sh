#!/bin/bash
set -euo pipefail
model_dir="${1:-$HOME/Library/Application Support/Doongdoong/Models}"
# Existing 둥둥이 installations already have these weights; avoid a duplicate GB download.
if [[ $# -eq 0 && ! -f "$model_dir/ggml-large-v3-turbo.bin" && -f "$HOME/Library/Application Support/Sori/Models/ggml-large-v3-turbo.bin" ]]; then
    model_dir="$HOME/Library/Application Support/Sori/Models"
fi
command -v whisper-server >/dev/null || { echo '먼저 brew install whisper.cpp를 실행하세요.' >&2; exit 1; }
mkdir -p "$model_dir"
lock_dir="$model_dir/.transcription-setup.lock"
mkdir "$lock_dir" 2>/dev/null || { echo '모델 준비가 이미 진행 중입니다.' >&2; exit 1; }
partial=""
cleanup() { [[ -z "$partial" ]] || rm -f -- "$partial"; rmdir "$lock_dir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() {
    local name="$1" expected="$2" source="$3"
    local destination="$model_dir/$name"
    if [[ -f "$destination" && "$(shasum -a 256 "$destination" | cut -d ' ' -f 1)" == "$expected" ]]; then
        echo "$name: 검증 완료"; return
    fi
    partial="$(mktemp "$model_dir/.download.XXXXXX")"
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 3600 --output "$partial" "$source"
    [[ "$(shasum -a 256 "$partial" | cut -d ' ' -f 1)" == "$expected" ]] || { echo '모델 검증 실패' >&2; exit 1; }
    mv -f "$partial" "$destination"
    partial=""
}
fetch ggml-large-v3-turbo.bin 1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
fetch ggml-silero-v6.2.0.bin 2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987 \
    https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin
echo "음성 인식 준비 완료: $model_dir"
