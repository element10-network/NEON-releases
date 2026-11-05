#!/bin/sh
# An atom's own name, made up on its first boot (owner, 2026-11-03): testers asked for "the atom's
# name" gave either their own name or a machine's, so the machine now names itself and the setup
# page asks for the person's name (the profile). Prints <word>-<word>-<word>, e.g.
# amber-quiet-otter (owner 2026-11-05: three words, no "neon-" in front): easy to say on the
# phone, and the same after a reinstall or a new SD card, because it comes from the board itself:
# the Pi's serial number (else the first network card's address, else the system's machine ID).
# Two different adjectives of 256 and a noun of 256: 16,711,680 names. Every word has 8 letters at
# most, so a name has 26 at most and fits every limit (MeshCore's 31 bytes, an SSID's 32 with
# "Neon-" in front, Meshtastic's 39). Two atoms may still get the same one; nothing depends on it
# being unique (an atom is known by its key; on one network avahi adds -2).
# neon-firstboot.sh always names the atom with it; network.sh renames one still called raspberrypi.
set -eu
ADJ="
    able agile airy amber ample aqua arctic ashen autumn azure balanced balmy bold bouncy brave
    breezy bright brisk bronze busy calm candid careful casual cedar cheerful cheery chill clear
    clever cloudy cobalt cool copper coral cosmic cozy crimson crisp cubic curly dapper daring dawn
    deep dreamy dusky dusty eager early easy ebony elder epic even exact fabled fair fancy fast
    fearless fern fiery fine firm first fleet fluffy foggy frank free fresh friendly frosty frugal
    gallant gentle giant gilded glad gleaming glossy golden graceful grand great green happy hardy
    hazel hazy hearty helpful hollow honest humble icy ideal indigo inner iron ivory jade jaunty
    jolly jovial joyful keen kind large lavish lemon level light lilac lime linen lively lofty loyal
    lucky lunar lush magic maple marble mellow merry mighty mild mindful minty mirth misty modest
    mossy mystic nimble noble north nova novel oaken ocean olive opal open orange outer pale patient
    peach pearl petite pine placid plain playful plucky plum polar polite prime proud quaint quick
    quiet quirky radiant rainy rapid rare ready regal rich ripe robust rocky rosy royal ruby rugged
    rustic sage sandy scarlet serene sharp shiny silent silky silver simple sincere sleek smart
    smooth snowy snug social solar solid sonic sparkly spicy spring spry steady stellar stoic sturdy
    sublime summer sunlit sunny sweet swift tall tawny teal tender thankful thrifty tidy tiny
    tireless topaz tough tranquil tropic true trusty tulip upbeat upper urban vast velvet vibrant
    vital vivid warm wavy west nifty wild windy winter wise witty wonder wooden woody young
    zesty zippy
"
NOUN="
    acorn agate alder alpaca anchor antelope arrow ash aspen aster aurora badger basalt basil bat
    bay beacon beagle bear beaver beryl birch bison bloom bobcat boulder branch breeze brook bud
    camel canoe canyon carp cave cheetah chipmunk clam cliff cloud clover collie comet compass
    condor cone corgi cougar cove coyote crab crane creek daisy deer delta dingo dolphin donkey dove
    duck dune eagle egret elk elm ember falcon ferret field finch fir flame flint forest fox frog
    frost garnet gazelle gecko glacier glade goat goose gopher granite grove gull hamster harbor
    hare harrier hawk heather hedgehog heron hill holly horse husky hyena ibis iguana impala iris
    island ivy jackal jaguar jasper jay juniper kayak kestrel kettle kite koala lake lamb lantern
    larch lark laurel leaf lemur leopard lily linnet lion llama lobster lotus lynx magpie marlin
    marten martin mast meadow meerkat merlin mesa meteor mink mint mole mongoose moon moose moss
    mouse mule narwhal nebula newt oak ocelot onyx orca orchid oriole osprey otter owl ox oyster
    panda parrot peak pebble pelican perch petal pigeon pike planet plover pond pony poodle poplar
    poppy possum prairie puffin puma quartz rabbit raccoon rain raven ray reed reef ridge river
    robin root rose rowan rudder rush sail salmon seal seed shark sheep shrew shrimp skunk sloth
    snail snow spaniel spark sparrow spruce squid squirrel stag star stoat stork storm stream summit
    sun swan tapir tern terrier thistle thrush thunder thyme tiger toad tortoise toucan trout tuna
    turtle valley violet vole walnut walrus weasel whale willow wolf wren yak zebra
"
# ATOM_NAME_ID: the board's ID given by hand (to see the name another board would get, and in tests).
id=${ATOM_NAME_ID:-}
[ -n "$id" ] || id=$(tr -d '\000' 2>/dev/null < /sys/firmware/devicetree/base/serial-number || true)
[ -n "$id" ] || id=$(sed -n 's/^Serial[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)
# A serial of zeros (some boards) names nothing.
case "$id" in *[!0[:space:]]*) ;; *) id= ;; esac
[ -n "$id" ] || id=$(cat /sys/class/net/eth0/address /sys/class/net/end0/address /sys/class/net/wlan0/address 2>/dev/null | head -n 1)
[ -n "$id" ] || id=$(cat /etc/machine-id 2>/dev/null || true)
[ -n "$id" ] || { echo "atom-name.sh: nothing to name this board by" >&2; exit 1; }
h=$(printf 'neon-atom-name:%s' "$id" | sha256sum | cut -c1-6)
pick() { printf '%s' "$1" | tr -s ' \n' '\n\n' | sed '/^$/d' | sed -n "$(($2 + 1))p"; }
# The first adjective and the noun from the same digits as the two-word names before 2026-11-05
# (neon-amber-otter becomes amber-<word>-otter after a reflash); the second adjective from the next.
b1=$((0x$(printf '%s' "$h" | cut -c1-2)))
b3=$((0x$(printf '%s' "$h" | cut -c3-4)))
b2=$((0x$(printf '%s' "$h" | cut -c5-6)))
# The second adjective is never the first: one of the other 255.
b2=$((b2 % 255))
[ "$b2" -lt "$b1" ] || b2=$((b2 + 1))
a=$(pick "$ADJ" "$b1")
a2=$(pick "$ADJ" "$b2")
n=$(pick "$NOUN" "$b3")
[ -n "$a" ] && [ -n "$a2" ] && [ -n "$n" ] || { echo "atom-name.sh: word lists broken" >&2; exit 1; }
echo "$a-$a2-$n"
