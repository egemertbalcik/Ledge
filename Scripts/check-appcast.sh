#!/bin/bash
# Refuses a feed whose newest update could reach a Mac that can't open it.
#
# usage: check-appcast.sh <appcast.xml>
#
# Ledge is Apple Silicon only from 1.3.0, and earlier versions were universal, so
# an Intel Mac can be running one of them. generate_appcast marks an arm64-only
# update with sparkle:hardwareRequirements, which is what stops Sparkle offering
# it there. Without the mark Sparkle installs it and the app no longer opens,
# with no update path back. The feed is also trimmed by hand, so run this again
# on the trimmed file before uploading it.
set -euo pipefail

FEED="${1:?usage: check-appcast.sh <appcast.xml>}"
[[ -f "$FEED" ]] || { echo "error: no feed at $FEED" >&2; exit 1; }

# Older items were universal and rightly carry no mark. Only the newest matters.
perl -0777 -e '
    my $feed = <STDIN>;
    my ($newest, $best) = ("", -1);
    while ($feed =~ m{<item>(.*?)</item>}gs) {
        my $item = $1;
        next unless $item =~ m{<sparkle:version>\s*(\d+)\s*</sparkle:version>};
        ($newest, $best) = ($item, $1) if $1 > $best;
    }
    if ($best < 0) {
        print STDERR "error: no versioned item in the feed\n";
        exit 1;
    }
    unless ($newest =~ m{<sparkle:hardwareRequirements>\s*arm64\s*</sparkle:hardwareRequirements>}) {
        print STDERR "error: build $best is not marked arm64, so Sparkle would offer it to Intel Macs\n";
        exit 1;
    }
' < "$FEED"
