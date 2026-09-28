FROM bats/bats:1.11.0

# The bats image is alpine plus bats. Everything the runner and the parsers call at
# runtime has to be here, or a test failure reads as a defect in the code under test.
#
# gawk, not busybox awk: guard_is_number and every threshold comparison run through
# awk, and the two differ on printf rounding.
# libxml2-utils carries xmllint, which the clover and junit parsers use.
# python3 runs the Claude Code hooks in templates/claude-hooks/; util-linux-misc carries
# script(1), which gives the override tests a real /dev/tty.
RUN apk add --no-cache \
    bash \
    git \
    grep \
    findutils \
    coreutils \
    gawk \
    jq \
    libxml2-utils \
    python3 \
    util-linux-misc

WORKDIR /code

CMD ["--recursive", "tests/"]
