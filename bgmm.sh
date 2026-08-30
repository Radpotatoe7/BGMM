#!/usr/bin/env bash
#--------------------
# BGMM.sh
# Pauses your chosen music player whenever another app starts playing audio (browser, another player, a game, etc.), and resumes it -- with a fade in/out -- once that audio stops. 
# Like Opera GX's background music ducking (weird word for that), but for any MPRIS-compatible player on Linux + PipeWire.
#
# if you running hyprland make sure to make this an exec-once in the config cause this is very cool
#
# Requirements (Arch or any distro (hopefully)):
#   playerctl = for actually controlling your music player
#   jq = 
#-----------------------
# First run: walks you through picking your player and detecting its real
# audio stream name(s), then saves that to a config file so future runs skip straight to watching.
#
# Why the "detect real stream name" step exists:
# Some players report a different name to PipeWire than their MPRIS name -- e.g. Namida (Cool ass music player check it out) embeds mpv
# ,so its audio stream shows up as "mpv" rather than "namida". 
# This wizard catches that automatically instead of you having to debug it by hand, whatever player you use.
#--------------------------
set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/BGMM" #config directory here
CONFIG_FILE="$CONFIG_DIR/config"

POLL_INTERVAL=0.5       # seconds between checks (lowering could add a teeeny tiny bit of cpu power usage , but makes it respond faster)
FADE_DURATION=0.8     # total seconds for a fade (increase this and steps for making it sound like you are recovering from a grenade)
FADE_STEPS=12          # more steps = smoother fade, more pactl calls (doesnt add any (significant) cpu load)

if [[ "${1:-}" == "--reconfigure" ]]; then #running ./bgmm.sh --reconfigure triggers first time setup again
  rm -f "$CONFIG_FILE"
fi

run_first_time_setup() { #first time setup function.
  echo "=== music-duck first-time setup ==="
  echo

  #Step 1 : find players to latch on
  mapfile -t players < <(playerctl -l 2>/dev/null) #playerctl usage 1
  if [[ ${#players[@]} -gt 0 ]]; then
    echo "MPRIS players currently detected:"
    local i=1
    for p in "${players[@]}"; do #listing all the listable players with playerctl
      echo "  $i) $p"
      ((i++))
    done
    echo
  else # i dont think anyone should get this while a player is playing
    echo "(No MPRIS players detected right now -- make sure yours is open,"
    echo " ideally playing something, then you can still type its name below.)"
    echo
  fi
  #input for step 1 , couldve made it number based.
  read -rp "Player name to control (must match playerctl -l exactly, e.g. 'spotify'): " PLAYER
  echo

  #Step 1.5 , setting up for step 2
  echo "Now play something in $PLAYER so its real audio stream can be detected."
  read -rp "Press Enter once it's actively playing... "
  echo

  #pactl usage 1
  mapfile -t stream_names < <(pactl -f json list sink-inputs 2>/dev/null | jq -r ' .[] | select(.corked == false) |(.properties["application.name"] // .properties["media.name"] // "unknown")' | sort -u)

  SELF_NAMES=()
  if [[ ${#stream_names[@]} -eq 0 ]]; then #again , no one should get this (hopefully)
    echo "No active audio streams found -- is it actually playing? Falling back"
    echo "to just matching on '$PLAYER' as the stream name."
    SELF_NAMES=("$PLAYER")
  # Step 2 : Latching on audio stream of the player too.
  else 
    echo "Active audio streams found:"
    local i=1
    for s in "${stream_names[@]}"; do
      echo "  $i) $s"
      ((i++))
    done
    echo
    read -rp "Which number(s) belong to $PLAYER? (space-separated, e.g. '1 3'): " selections
    for n in $selections; do
      SELF_NAMES+=("${stream_names[$((n - 1))]}")
    done
    SELF_NAMES+=("$PLAYER")
  fi
  echo

  #Step 3 : Fade enable or disable
  read -rp "I want you to use Fade In/Out because it's cool , do you want it tho ? [Y/n]: " fade_choice
  if [[ "${fade_choice,,}" == "n" ]]; then
    echo "aw phooey."
    FADE_ENABLED=0
  else
    FADE_ENABLED=1 #like god intended
  fi

  mkdir -p "$CONFIG_DIR" #actually making the config now
  {
    echo "PLAYER=\"$PLAYER\""
    printf 'SELF_NAMES=('
    for n in "${SELF_NAMES[@]}"; do
      printf '"%s" ' "${n,,}"
    done
    printf ')\n'
    echo "FADE_ENABLED=$FADE_ENABLED"
  } > "$CONFIG_FILE" #and putting all the given info there so that i dont ask it every time.

  echo
  echo "Saved to $CONFIG_FILE"
  echo "(delete this file, or run ./bgmm.sh --reconfigure to redo setup)"
  echo
  #Step: FIN for the setup
}
#------------------------------------
#now comes the fun part

if [[ -f "$CONFIG_FILE" ]]; then #if configurations are already there we just go to the fun part
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
else
  run_first_time_setup
fi

#---------------------------------------
ducked=0   # 1 if we paused the player,so we know to resume it

#checks if our player is actually playing rn
is_self_name() {
  local lname="$1"
  for n in "${SELF_NAMES[@]}"; do
    [[ "$lname" == *"$n"* ]] && return 0
  done
  return 1
}

# Sink-input indices belonging to the player, so we can fade their volume directly.
# This is a separate multiplicative gain on top of whatever the player's own internal volume is set to -- resetting to 100% always means "no change from the player's own setting," regardless of what that is.
player_sink_input_indices() { #pactl usage 2
  pactl -f json list sink-inputs 2>/dev/null | jq -r --argjson names "$(printf '%s\n' "${SELF_NAMES[@]}" | jq -R . | jq -s .)" '
    .[] | select(
      ((.properties["application.name"] // .properties["media.name"] // "")
        | ascii_downcase) as $name |
      any($names[]; . as $n | $name | contains($n))
    ) | .index
  '
}

#the function for the gods
fade_player() {
  local direction="$1"   # "out" or "in"
  local idx pct i step_delay
  step_delay=$(awk -v d="$FADE_DURATION" -v s="$FADE_STEPS" 'BEGIN{print d/s}')

  for idx in $(player_sink_input_indices); do
    for ((i = 0; i <= FADE_STEPS; i++)); do
      if [[ "$direction" == "out" ]]; then # high to low (when other thingy plays)
        pct=$(( 100 - (100 * i / FADE_STEPS) ))
      else # low to high (when other thingy pauses)
        pct=$(( 100 * i / FADE_STEPS ))
      fi
      pactl set-sink-input-volume "$idx" "${pct}%" 2>/dev/null #pactl usage 3
      sleep "$step_delay"
    done
  done
}

#imagine not using fade , and directly pause-play ing
reset_player_volume() {
  local idx
  for idx in $(player_sink_input_indices); do
    pactl set-sink-input-volume "$idx" "100%" 2>/dev/null #pactl usage 4
  done
}

#very important function , actually allows this entire thing to work.
is_other_audio_active() {
  local name corked mute lname
  while IFS=$'\t' read -r name corked mute; do
    [[ -z "$name" && -z "$corked" ]] && continue
    [[ "$corked" == "true" ]] && continue
    [[ "$mute" == "true" ]] && continue
    lname=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    if ! is_self_name "$lname"; then
      return 0   # found a some other active stream
    fi
  #pactl usage 5
  done < <(pactl -f json list sink-inputs 2>/dev/null | jq -r '
      .[] | [
        (.properties["application.name"] // .properties["media.name"] // "unknown"),
        (.corked | tostring),
        (.mute | tostring)
      ] | @tsv
    ')
  return 1
}

#playerctl usage 2
player_is_playing() { 
  [[ "$(playerctl -p "$PLAYER" status 2>/dev/null)" == "Playing" ]]
}

echo "BGMM running for '$PLAYER' (checking every ${POLL_INTERVAL}s, fade: $([[ "$FADE_ENABLED" -eq 1 ]] && echo on || echo off))..."
reset_player_volume   # in case a previous run was killed mid-fade

#using all the previous helper function to actually do what im supposed to do. (so like the main function)
while true; do #and by true it means forever , or as long as the sh is running
  if is_other_audio_active; then 
    #code when any other audio source is playing , turn our music off
    if [[ "$ducked" -eq 0 ]] && player_is_playing; then 
      [[ "$FADE_ENABLED" -eq 1 ]] && fade_player out
      playerctl -p "$PLAYER" pause #playerctl (important) usage 3
      reset_player_volume
      ducked=1
    fi
  else
    #when any other isnt playing , turn our music back on with style
    if [[ "$ducked" -eq 1 ]]; then
      if [[ "$FADE_ENABLED" -eq 1 ]]; then #as the lord wanted it to be
        for idx in $(player_sink_input_indices); do
          pactl set-sink-input-volume "$idx" "0%" 2>/dev/null #pactl usage 6
        done
        playerctl -p "$PLAYER" play  #playerctl (important) usage 0.5
        fade_player in
      else
        #imagine just breaking pause-play , couldnt be me
        playerctl -p "$PLAYER" play #playerctl (important) usage the other 0.5
      fi
      ducked=0
    fi
  fi
  sleep "$POLL_INTERVAL"
done
# END OF CODE BABY LETS GO

# some backup if your pactl doesnt support json for some reason. (bro just update dear god)
# --- FALLBACK (no JSON support in your pactl) ---------------------------
# Replace is_other_audio_active() with something like:
#
# is_other_audio_active() {
#   pactl list sink-inputs 2>/dev/null | awk -v names="${SELF_NAMES[*]}" '
#     BEGIN{split(names, arr, " "); active=0; app=""; corked=""}
#     /^Sink Input #/{app=""; corked=""}
#     /application\.name = /{ gsub(/.*= "|"$/,""); app=tolower($0) }
#     /Corked: /{ corked=$2 }
#     /^$/{
#       is_self=0
#       for (i in arr) if (index(app, arr[i]) > 0) is_self=1
#       if (app != "" && corked == "no" && !is_self) active=1
#     }
#     END{ exit !active }
#   '
# }
