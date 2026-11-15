#!/usr/bin/env bash
# shellcheck shell=bash
#
# Simulates the documented Postfix recipient lookup used for relay domains:
#   1. the domain must match relay_domains;
#   2. the full recipient address is looked up;
#   3. the address is retried with the recipient_delimiter extension removed;
#   4. the "@domain" wildcard is tried last.
#
# This mirrors mail_addr_find(3) and is used to test the generated maps without
# starting a real MTA.

postfix_lookup_domain() {
    local maps_dir=$1 domain=$2
    awk -v k="$domain" 'tolower($1) == tolower(k) { found = 1; exit } END { exit !found }' \
        "$maps_dir/relay_domains"
}

postfix_lookup_recipient() {
    local maps_dir=$1 address=$2
    awk -v k="$address" 'tolower($1) == tolower(k) { found = 1; exit } END { exit !found }' \
        "$maps_dir/relay_recipients"
}

postfix_decision() {
    local maps_dir=$1 address=$2 localpart domain base
    address=${address,,}

    if [[ $address != *@* ]]; then
        printf 'reject-invalid'
        return 0
    fi
    localpart=${address%@*}
    domain=${address##*@}

    if ! postfix_lookup_domain "$maps_dir" "$domain"; then
        printf 'reject-domain'
        return 0
    fi
    if postfix_lookup_recipient "$maps_dir" "$address"; then
        printf 'accept'
        return 0
    fi
    if [[ $localpart == *+* ]]; then
        base=${localpart%%+*}
        if postfix_lookup_recipient "$maps_dir" "$base@$domain"; then
            printf 'accept'
            return 0
        fi
    fi
    if postfix_lookup_recipient "$maps_dir" "@$domain"; then
        printf 'accept'
        return 0
    fi
    printf 'reject-recipient'
}
