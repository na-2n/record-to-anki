#!/bin/sh

# Config
anki_profile="ユーザー 1"
card_audio_field="SentenceAudio"
normalize=1
wait_sec=3

# Probably shouldn't need to change these
tmp_dir="/tmp"
fn="anki_audio"
pid_file="$tmp_dir/$fn.pid"
rec_file="$tmp_dir/$fn.wav"
mp3_file="$tmp_dir/$fn.mp3"
norm_file="$tmp_dir/${fn}_norm.wav"
anki_media_dir=""
ankiconnect_url="http://localhost:8765"
replaceid=1373
appname="ankiaudio"
norm_integrated="-16"
norm_truepeak="-1.5"
norm_lra="11"
output_format="rec_%Y%m%d_%H%M%S.mp3"

# vars
playback_audio=0
use_clipboard=0
media_name=""
rec_pid=0

ankiconnect() {
    curl $ankiconnect_url -X POST -H "Content-Type: application/json; charset=UTF-8" -d "$1" 2>/dev/null
}

_is_mac() {
    [[ "$OSTYPE" = "darwin"* ]]
}

_record_mac() {
    audiotee --stereo --sample-rate 44100 2>/dev/null | ffmpeg -y -ac 2 -f s16le -i pipe: $rec_file 2>/dev/null
}

_record_pw() {
    pw-record -P '{ stream.capture.sink=true }' $rec_file
}

record_audio() {
    case "$OSTYPE" in
        "darwin"*)
            _record_mac &

            rec_pid=$(pgrep -of "audiotee")
            ;;

        "linux"* | "freebsd"*)
            _record_pw &

            rec_pid=$(pgrep -of "pw-record")
            ;;

        *)
            echo "Unsupported OS"
            exit 1
            ;;
    esac
}

_close_notif_dbus() {
    dbus-send                                           \
        --session                                       \
        --type=method_call                              \
        --dest=org.freedesktop.Notifications            \
        /org/freedesktop/Notifications                  \
        org.freedesktop.Notifications.CloseNotification \
        uint32:$1

    # sleep to ensure the notification has been closed before we attempt to make any new ones
    sleep 0.1
}

close_notif() {
    case "$OSTYPE" in
        "darwin"*)
            terminal-notifier -remove $replaceid
            ;;

        "linux"* | "freebsd"*)
            _close_notif_dbus
            ;;

        *)
            echo "Unsupported OS"
            exit 1
            ;;
    esac
}

_notify_dbus() {
    lvl="$1"
    inf=0

    if "$lvl" == "inf"*; then
        lvl="normal"
        inf=1
    fi

    notify-send $([ $inf -eq 1 ] && echo "-t 0") -a $appname -r $replaceid -u "$lvl" "$2" "$3"
}

_notify_mac() {
    terminal-notifier -ignoreDnD -group $replaceid -title "$1" -message "$2"
}

notify() {
    case "$OSTYPE" in
        "darwin"*)
            _notify_mac "$2" "$3"
            ;;

        "linux"* | "freebsd"*)
            _notify_dbus "$1" "$2" "$3"
            ;;

        *)
            echo "Unsupported OS"
            exit 1
            ;;
    esac
}

play_audio() {
    mpv --no-config --force-window=no --loop-file=no --load-scripts=no "$1"
}

copy_mp3() {
    if ! cp $mp3_file "$anki_media_dir/$media_name"; then
        notify critical "Adding to card failed!" "Failed to copy file to Anki media directory, is it configured correctly?"
        exit 1
    fi

    if [ $1 -eq 1 ]; then
        notify normal "Added to card!"
    fi

    if [ $playback_audio -eq 1 ]; then
        play_audio "$anki_media_dir/$media_name"
    fi
}

while getopts pcnfrh o; do
    case $o in
        p):
            playback_audio=1
            ;;
        c):
            use_clipboard=1
            ;;
        n):
            wait_sec=0
            ;;
        f):
            rm $rec_file
            rm $pid_file
            ;;
        r):
            rm $rec_file
            rm $pid_file

            exit 0
            ;;
        h):
            echo "Usage:"
            echo "  $0 [options]"
            echo
            echo "Options:"
            echo "  -p  Enable audio playback"
            echo "  -c  Copy media string to clipboard instead of adding it to the last card"
            echo "  -n  Start recording immediately"
            echo "  -r  Remove temporary files"
            echo "  -f  Same as -r but does not exit"
            echo "  -h  Show this message"

            exit 0
            ;;
    esac
done

if [ -z "$anki_media_dir" ]; then
    case "$OSTYPE" in
        "linux"* | "freebsd"*)
            anki_media_dir="$HOME/.local/share/Anki2/$anki_profile/collection.media"
            ;;

        "darwin"*)
            anki_media_dir="$HOME/Library/Application Support/Anki2/$anki_profile/collection.media"
            ;;

        *)
            echo "Unsupported OS, could not resolve anki media dir. Please set it manually"
            exit 1
            ;;
    esac
fi

if [ -e "$pid_file" ] && ps "$(cat "$pid_file")" >/dev/null; then
    kill "$(cat $pid_file)"
    rm $pid_file

    # kills the old process' notify-send so it closes the notification and stops the process
    if ! _is_mac; then
        pkill --signal SIGINT -f "notify-send.+$replaceid"
    fi

    notify inf "Adding to card..."

    if [ $normalize -eq 1 ]; then
        if ! ffmpeg -y -i $rec_file -filter:a "silenceremove=1:0:-50dB" $norm_file; then
            notify critical "Adding to card failed!" "FFmpeg error"
            exit 1
        fi

        stat=$(ffmpeg -y -i $norm_file -af "loudnorm=I=$norm_integrated:dual_mono=true:tp=$norm_truepeak:LRA=$norm_lra:print_format=json" -f null - 2>&1 | grep -B11 '}')

        measured_integrated=$(echo $stat | jq '.input_i | tonumber')
        measured_truepeak=$(echo $stat | jq '.input_tp | tonumber')
        measured_lra=$(echo $stat | jq '.input_lra | tonumber')
        measured_thresh=$(echo $stat | jq '.input_thresh | tonumber')
        offset=$(echo $stat | jq '.target_offset | tonumber')

        #if ! ffmpeg-normalize $norm_file -o $mp3_file -c:a libmp3lame -e="-q:a 4"
        if ! ffmpeg -y \
            -i $norm_file \
            -c:a libmp3lame \
            -filter_complex "loudnorm=I=$norm_integrated:
                dual_mono=true:
                tp=$norm_truepeak:
                LRA=$norm_lra:
                measured_I=$measured_integrated:
                measured_LRA=$measured_lra:
                measured_TP=$measured_truepeak:
                measured_thresh=$measured_thresh:
                offset=$offset:
                linear=true" \
            -q:a 4 $mp3_file
        then
            notify critical "Adding to card failed!" "FFmpeg error"
            exit 1
        fi

        rm $norm_file
    else
        if ! ffmpeg -y -i $rec_file -c:a libmp3lame -filter:a "volume=0.9,silenceremove=1:0:-50dB" -q:a 4 $mp3_file; then
            notify critical "Adding to card failed!" "FFmpeg error"
            exit 1
        fi
    fi

    rm $rec_file

    media_name="$(date +"$output_format")"

    if [ $use_clipboard -eq 1 ]; then
        copy_mp3 0

        mstr="[sound:$media_name]"
        case "$XDG_SESSION_TYPE" in
            "wayland")
                wl-copy $mstr
                ;;
            "x11")
                echo $mstr | xclip -i -sel clipboard
                ;;
            "")
                if _is_mac; then
                    echo $mstr | pbcopy
                else
                    notify critical "Failed to copy to clipboard!" "Failed to infer whether we are running on Wayland or X11, are your XDG environment variables set up correctly?"
                    exit 1
                fi
                ;;
            *)
                notify critical "Failed to copy to clipboard!" "Unknown XDG_SESSION_TYPE"
                exit 1
                ;;
        esac

        notify normal "Copied to clipboard!"
    else
        if ! resp=$(ankiconnect '{"action":"findNotes","version":6,"params":{"query":"added:1"}}'); then
            notify critical "Adding to card failed!" "Failed to connect to anki, is it running?"
            exit 1
        fi

        card_id=$(echo $resp | jq '.result | sort | reverse[0]')

        if ! resp=$(ankiconnect '{"action":"updateNoteFields","version":6,"params":{"note":{"id":'$card_id',"fields":{"'$card_audio_field'":"[sound:'$media_name']"}}}}'); then
            notify critical "Adding to card failed!" "Failed to connect to anki, is it running?"
            exit 1
        fi

        if echo $resp | jq -e '.error == null' >/dev/null; then
            copy_mp3 1
        else
            err=$(echo $resp | jq '.error')

            notify critical "Adding to card failed!" "$err"
        fi
    fi

    rm $mp3_file
elif _r=$(pgrep -of "$0") && [ "$_r" != "$$" ]; then
    echo "Recording countdown in progress..."
    exit 1
else
    close_notif $replaceid

    if [ $wait_sec -gt 0 ]; then
        msg="Recording in $wait_sec seconds..."

        if [ $wait_sec -eq 1 ]; then
            msg="Recording in a second..."
        fi

        echo "$msg"
        notify inf "$msg"

        sleep $wait_sec
    fi

    record_audio
    echo "$rec_pid" > "$pid_file"

    echo "Recording audio..."

    if _is_mac; then
        terminal-notifier                           \
            -ignoreDnD                              \
            -groups $replaceid                      \
            -title "Recording audio..."             \
            -message "Click notification to cancel" \
            -execute "kill $rec_pid && rm $rec_file && rm $pid_file"
    else
        resp=$(notify-send -u normal -a $appname -r $replaceid -t 0 -A Abort -A Stop "Recording audio...")

        case "$resp" in
            '0')
                kill $rec_pid
                rm $rec_file
                rm $pid_file
                ;;
            '1')
                /bin/sh $0 $@
                ;;
        esac
    fi
fi

