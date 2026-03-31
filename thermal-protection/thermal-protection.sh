#!/bin/bash
#
# Thermal Protection Daemon
# Monitors CPU and ambient temperatures, plays alarm sounds when thresholds exceeded.
# Designed to work with zero dependencies on Viam, internet, or Chef module.
#
# Usage: Runs as a systemd service (thermal-protection.service)
# Logs: journalctl -u thermal-protection -f
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment / systemd Environment=)
# ---------------------------------------------------------------------------
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Thresholds (°C) — either CPU OR ambient crossing triggers the stage
CPU_WARN_THRESHOLD="${CPU_WARN_THRESHOLD:-80}"
CPU_ALARM_THRESHOLD="${CPU_ALARM_THRESHOLD:-90}"
AMBIENT_WARN_THRESHOLD="${AMBIENT_WARN_THRESHOLD:-65}"
AMBIENT_ALARM_THRESHOLD="${AMBIENT_ALARM_THRESHOLD:-80}"

# Hysteresis: temps must drop this many °C below threshold to clear
HYSTERESIS="${HYSTERESIS:-3}"

# Warning: one-shot TTS, won't repeat for this many seconds
WARNING_COOLDOWN="${WARNING_COOLDOWN:-300}"

# Alarm: seconds of alarm beeps between TTS announcements
ALARM_TTS_INTERVAL="${ALARM_TTS_INTERVAL:-18}"

# Audio files
AUDIO_DIR="${AUDIO_DIR:-/usr/local/share/thermal-protection}"
ALARM_WAV="$AUDIO_DIR/alarm.wav"
WARNING_WAV="$AUDIO_DIR/warning.wav"
ALARM_VOICE_WAV="$AUDIO_DIR/alarm-voice.wav"

# Ambient sensor source — set to override auto-detection
# e.g. /sys/class/hwmon/hwmon2/temp1_input or /sys/class/thermal/thermal_zone1/temp
AMBIENT_TEMP_SOURCE="${AMBIENT_TEMP_SOURCE:-}"

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
STATE="NORMAL"  # NORMAL, WARNING, ALARM
ALARM_LOOP_PID=""
LAST_WARNING_TTS=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo "[WARN]  $(date '+%H:%M:%S') $*"; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*"; }

# ---------------------------------------------------------------------------
# Sensor discovery
# ---------------------------------------------------------------------------
CPU_TEMP_PATH="/sys/class/thermal/thermal_zone0/temp"

find_ambient_sensor() {
    # Explicit override
    if [[ -n "$AMBIENT_TEMP_SOURCE" ]] && [[ -f "$AMBIENT_TEMP_SOURCE" ]]; then
        echo "$AMBIENT_TEMP_SOURCE"
        return
    fi

    # Additional thermal zones (zone0 is CPU)
    local zone
    for zone in /sys/class/thermal/thermal_zone{1..9}; do
        if [[ -f "$zone/temp" ]]; then
            log_info "Found ambient sensor: $zone/temp ($(cat "$zone/type" 2>/dev/null || echo unknown))"
            echo "$zone/temp"
            return
        fi
    done

    # hwmon devices — skip known CPU sensors
    local hwmon name
    for hwmon in /sys/class/hwmon/hwmon*; do
        [[ -f "$hwmon/temp1_input" ]] || continue
        name=$(cat "$hwmon/name" 2>/dev/null || echo "")
        case "$name" in
            cpu_thermal|soc_thermal|coretemp|cpu-thermal) continue ;;
        esac
        log_info "Found ambient sensor: $hwmon/temp1_input (name=$name)"
        echo "$hwmon/temp1_input"
        return
    done

    echo ""
}

read_millidegrees() {
    # Read a sysfs temp file (millidegrees C) and return degrees C
    local path="$1"
    if [[ -f "$path" ]]; then
        local raw
        raw=$(cat "$path" 2>/dev/null) || return 1
        echo $(( raw / 1000 ))
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Audio playback
# ---------------------------------------------------------------------------
play_audio() {
    local file="$1"
    if [[ -f "$file" ]]; then
        aplay -q "$file" 2>/dev/null || true
    fi
}

# Alarm loop: repeating alarm beeps with periodic TTS voice announcement
# Runs as a background process, killed on state transition
alarm_loop() {
    trap 'exit 0' TERM INT
    while true; do
        # Play alarm beeps for ALARM_TTS_INTERVAL seconds
        local end_time=$(( $(date +%s) + ALARM_TTS_INTERVAL ))
        while [[ $(date +%s) -lt $end_time ]]; do
            aplay -q "$ALARM_WAV" 2>/dev/null || sleep 1
        done
        # Play TTS voice announcement
        aplay -q "$ALARM_VOICE_WAV" 2>/dev/null || true
    done
}

start_alarm() {
    if [[ -n "$ALARM_LOOP_PID" ]] && kill -0 "$ALARM_LOOP_PID" 2>/dev/null; then
        return  # Already running
    fi
    log_warn "Starting alarm audio"
    alarm_loop &
    ALARM_LOOP_PID=$!
}

stop_alarm() {
    if [[ -n "$ALARM_LOOP_PID" ]]; then
        log_info "Stopping alarm audio"
        # Kill alarm loop and any child aplay processes
        kill "$ALARM_LOOP_PID" 2>/dev/null || true
        pkill -P "$ALARM_LOOP_PID" 2>/dev/null || true
        wait "$ALARM_LOOP_PID" 2>/dev/null || true
        ALARM_LOOP_PID=""
    fi
}

play_warning_tts() {
    local now
    now=$(date +%s)
    if (( now - LAST_WARNING_TTS >= WARNING_COOLDOWN )); then
        log_warn "Playing warning TTS"
        play_audio "$WARNING_WAV"
        LAST_WARNING_TTS=$now
    fi
}

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
determine_stage() {
    local cpu_temp="$1"
    local ambient_temp="$2"  # May be empty string if no sensor

    # Check alarm thresholds
    local alarm=false
    if (( cpu_temp >= CPU_ALARM_THRESHOLD )); then
        alarm=true
    fi
    if [[ -n "$ambient_temp" ]] && (( ambient_temp >= AMBIENT_ALARM_THRESHOLD )); then
        alarm=true
    fi
    if $alarm; then
        echo "ALARM"
        return
    fi

    # Check warning thresholds
    local warn=false
    if (( cpu_temp >= CPU_WARN_THRESHOLD )); then
        warn=true
    fi
    if [[ -n "$ambient_temp" ]] && (( ambient_temp >= AMBIENT_WARN_THRESHOLD )); then
        warn=true
    fi
    if $warn; then
        echo "WARNING"
        return
    fi

    echo "NORMAL"
}

should_clear_stage() {
    # Apply hysteresis: temps must drop below threshold - hysteresis to clear
    local cpu_temp="$1"
    local ambient_temp="$2"
    local current_state="$3"

    case "$current_state" in
        ALARM)
            # Clear alarm if CPU below alarm-hysteresis AND ambient below alarm-hysteresis
            if (( cpu_temp < CPU_ALARM_THRESHOLD - HYSTERESIS )); then
                if [[ -z "$ambient_temp" ]] || (( ambient_temp < AMBIENT_ALARM_THRESHOLD - HYSTERESIS )); then
                    return 0  # Clear
                fi
            fi
            return 1  # Stay in alarm
            ;;
        WARNING)
            # Clear warning if CPU below warn-hysteresis AND ambient below warn-hysteresis
            if (( cpu_temp < CPU_WARN_THRESHOLD - HYSTERESIS )); then
                if [[ -z "$ambient_temp" ]] || (( ambient_temp < AMBIENT_WARN_THRESHOLD - HYSTERESIS )); then
                    return 0  # Clear
                fi
            fi
            return 1  # Stay in warning
            ;;
    esac
    return 0
}

transition_to() {
    local new_state="$1"
    local cpu_temp="$2"
    local ambient_temp="$3"

    if [[ "$STATE" == "$new_state" ]]; then
        return
    fi

    local ambient_str="${ambient_temp:-N/A}"
    log_warn "State transition: $STATE -> $new_state (CPU=${cpu_temp}°C, Ambient=${ambient_str}°C)"

    # Exit old state
    case "$STATE" in
        ALARM) stop_alarm ;;
    esac

    # Enter new state
    case "$new_state" in
        WARNING)
            play_warning_tts
            ;;
        ALARM)
            start_alarm
            ;;
        NORMAL)
            LAST_WARNING_TTS=0
            ;;
    esac

    STATE="$new_state"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log_info "Shutting down thermal protection daemon"
    stop_alarm
    exit 0
}
trap cleanup SIGTERM SIGINT EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log_info "Thermal protection daemon starting"
log_info "Thresholds: CPU warn=${CPU_WARN_THRESHOLD}°C alarm=${CPU_ALARM_THRESHOLD}°C"
log_info "Thresholds: Ambient warn=${AMBIENT_WARN_THRESHOLD}°C alarm=${AMBIENT_ALARM_THRESHOLD}°C"
log_info "Hysteresis: ${HYSTERESIS}°C, Poll interval: ${POLL_INTERVAL}s"

# Verify CPU sensor
if [[ ! -f "$CPU_TEMP_PATH" ]]; then
    log_error "CPU temp sensor not found: $CPU_TEMP_PATH"
    exit 1
fi

# Find ambient sensor
AMBIENT_SENSOR_PATH=$(find_ambient_sensor)
if [[ -n "$AMBIENT_SENSOR_PATH" ]]; then
    log_info "Ambient sensor: $AMBIENT_SENSOR_PATH"
else
    log_warn "No ambient sensor found — monitoring CPU temp only"
    log_warn "Set AMBIENT_TEMP_SOURCE to specify sensor path"
fi

# Verify audio files
for f in "$ALARM_WAV" "$WARNING_WAV" "$ALARM_VOICE_WAV"; do
    if [[ ! -f "$f" ]]; then
        log_warn "Audio file missing: $f"
    fi
done

log_info "Monitoring started"

while true; do
    # Read temperatures
    cpu_temp=$(read_millidegrees "$CPU_TEMP_PATH") || { sleep "$POLL_INTERVAL"; continue; }

    ambient_temp=""
    if [[ -n "$AMBIENT_SENSOR_PATH" ]]; then
        ambient_temp=$(read_millidegrees "$AMBIENT_SENSOR_PATH") || ambient_temp=""
    fi

    # Determine target stage from raw readings
    target_stage=$(determine_stage "$cpu_temp" "$ambient_temp")

    # Apply state machine logic
    case "$STATE" in
        NORMAL)
            if [[ "$target_stage" == "ALARM" ]]; then
                transition_to "ALARM" "$cpu_temp" "$ambient_temp"
            elif [[ "$target_stage" == "WARNING" ]]; then
                transition_to "WARNING" "$cpu_temp" "$ambient_temp"
            fi
            ;;
        WARNING)
            if [[ "$target_stage" == "ALARM" ]]; then
                transition_to "ALARM" "$cpu_temp" "$ambient_temp"
            elif [[ "$target_stage" == "NORMAL" ]]; then
                if should_clear_stage "$cpu_temp" "$ambient_temp" "WARNING"; then
                    transition_to "NORMAL" "$cpu_temp" "$ambient_temp"
                fi
            else
                # Still in warning — check cooldown for repeat TTS
                play_warning_tts
            fi
            ;;
        ALARM)
            if [[ "$target_stage" != "ALARM" ]]; then
                if should_clear_stage "$cpu_temp" "$ambient_temp" "ALARM"; then
                    # Drop to warning or normal based on current readings
                    if [[ "$target_stage" == "WARNING" ]]; then
                        transition_to "WARNING" "$cpu_temp" "$ambient_temp"
                    else
                        transition_to "NORMAL" "$cpu_temp" "$ambient_temp"
                    fi
                fi
            fi
            ;;
    esac

    sleep "$POLL_INTERVAL"
done
