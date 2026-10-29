# DLNA multicast signing

SSDP sends multicast UDP to 239.255.255.250:1900. On physical iOS devices this requires Apple's approved `com.apple.developer.networking.multicast` entitlement, in addition to the user's Local Network permission. The simulator cannot validate this permission behavior.

After Apple enables the capability for your App ID, use a matching provisioning profile and set `CODE_SIGN_ENTITLEMENTS=Signing/Multicast.entitlements` when building/signing. The unsigned IPA contains no signature or entitlement grant. A signing service must include this entitlement in its signature and an Apple-issued profile that authorizes it; copying the plist into an IPA does not grant permission.

Manual addition of a known LAN device-description URL uses unicast HTTP and works without multicast entitlement, subject to Local Network permission. It uses the same device parser and SOAP controls as SSDP discovery. The app never guesses ports or scans unrelated hosts.

Apple primary reference: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
