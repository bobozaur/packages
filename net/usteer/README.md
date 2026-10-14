# Band steering policy

`band_steering_signal_threshold` is the signal improvement, in dB, required
above the station's learned signal threshold before band steering. The default
is 5. Set it to 0 to disable the adaptive improvement requirement;
`band_steering_min_snr` and the normal station, target and interval eligibility
checks still apply. This setting does not fabricate a signal measurement or
command a client transition. The client remains responsible for accepting a
BSS transition request.

The existing UCI option is loaded through the procd service configuration and
is available through the native `get_config`, `set_config` and `update_config`
methods. LuCI writes that same option. An omitted UCI value retains the default on configuration reload;
`update_config` leaves omitted settings unchanged.

Connected-station signal updates prefer the native nl80211 average when the
driver supplies it, otherwise they use the measured last-packet signal. Both
fields use signed dBm. An absent field is not replaced with zero or a synthetic
average. A new station remains unmeasured until a real sample arrives and cannot
be a roaming source or target while its signal is unknown.

Configuration updates refresh the effective `aggressiveness` of already known
stations, including MAC-specific overrides. Initial hostapd discovery can happen
before the init script applies UCI configuration, so stations must not retain the
startup default after that update. `connected_clients` and `get_client_info`
report the effective station value. Advisory or disabled policy retires usteer's
own pending transition kicks; it does not cancel an imminent-disassociation
timer that a previous request already handed to hostapd. Omitted callback options
remain unchanged in `update_config`, including a configured MAC override list.

Band-steering requests use a nonzero BSS Transition Management dialog token
owned by the station/BSS entry. The token advances for each request and wraps
from 255 to 1 in both advisory and imminent-disassociation policy paths. Zero is
reserved and is discarded by clients without a response. Existing request logs
include the token for correlation with the native hostapd response event.

Hostapd publishes query tokens and response status codes as 32-bit ubus integers.
Usteer validates their octet ranges before storing them, preserves a query's
token in its reply, and applies valid responses to the existing rejection and
request-timing policy. This does not change client acceptance decisions.
