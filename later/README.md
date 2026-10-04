# Deferred manifests

These files stay out of `manifests/` so a recursive apply does not
start them.

Unbound, Home Assistant, MQTT, weather, speedtest, and starlink wait
on the Home Assistant conversion. Pomerium waits on the sign-on work.
The CoreDNS file is the old commented stub. k3s ships its own CoreDNS.
