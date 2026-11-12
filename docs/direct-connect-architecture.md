# OmniDrop Direct connection architecture

The Direct tab is a separate transport from Nearby devices. Nearby devices keeps the existing local-network path. Direct connections will use BLE to find OmniDrop peers and a Wi-Fi peer link for the file bytes; BLE is only a discovery and negotiation channel.

## Platform transports

- **Windows to Android:** Android hosts a Wi-Fi Direct group and Windows joins it. Android requests 5 GHz where supported and reports an automatic-band fallback when the request fails. Windows may show an operating-system connection or pairing prompt and its public APIs do not allow OmniDrop to force a band.
- **Existing LAN mode:** mDNS and local-network transfers remain available when both devices share a network. Direct mode does not remove or silently replace this route.
- **Additional direct modes:** Wi-Fi Aware (NAN), BLE background discovery, Android-to-Android peer negotiation, and Windows-hosted groups are not implemented yet.

## Flutter integration

`DirectRadioService` calls `com.omnidrop/direct_radio`. Each platform reports support separately for Wi-Fi Direct, Wi-Fi Aware, and BLE. The Direct tab shows unsupported hardware, disabled radios, and platform limitations instead of presenting an unusable peer as ready.

## Current direct Wi-Fi Direct path

- Android can start a Wi-Fi Direct group as the group owner. On Android 10 and later OmniDrop requests the 5 GHz band; if the request fails it creates an automatic-band group. Earlier Android versions use automatic band selection.
- Windows enumerates nearby Wi-Fi Direct association endpoints, connects to the selected phone, and uses the remote endpoint address to reach OmniDrop's fixed direct listener on TCP port `53679`.
- A small identity exchange discovers the peer's OmniDrop device ID. Pairing and file bytes then use the existing verification-code pairing and authenticated encrypted transfer protocol. Nearby mDNS discovery remains available and is not replaced.
- Windows does not expose a public per-session band selector for Wi-Fi Direct, so OmniDrop makes Android host the group when the user wants a 5 GHz preference. The Android driver can still reject 5 GHz; automatic-band fallback is reported in the UI.

Wi-Fi Aware (NAN), BLE background discovery, Android-to-Android direct discovery, and Windows-hosted direct groups remain capability checks or future work. Direct sessions currently use Android as the group owner and Windows as the joining device.

## Security and lifecycle

- Require an explicit user action to connect and an explicit receiver decision for incoming transfers.
- Compare a short authentication string derived from an ephemeral key exchange before trusting a peer; persist peer keys only in platform secure storage.
- Encrypt file and chat payloads end to end, verify every chunk, and discard partial files on rejection or disconnect.
- Rotate BLE discovery tokens, stop scanning/advertising when visibility is off, and expire peers quickly after their last advertisement.
- Keep chat/transfers in memory for the active connection unless the user explicitly saves received content.

## Platform limits

Wi-Fi Aware is optional Android hardware/API support and can become unavailable when Wi-Fi, location-related system state, Wi-Fi Direct, tethering, or other radio modes conflict. Windows desktop Wi-Fi Direct APIs may require the user to pair the device in Windows first; Windows Mobile Hotspot can conflict with Wi-Fi Direct. BLE background scanning is best effort and restricted by operating-system lifecycle and adapter resources. Direct mode therefore requires runtime capability and availability checks on both endpoints; it cannot be guaranteed on every PC/phone combination.

References: [Android Wi-Fi Aware](https://developer.android.com/develop/connectivity/wifi/wifi-aware), [Android Wi-Fi Direct](https://developer.android.com/develop/connectivity/wifi/wifip2p), [Windows desktop Wi-Fi Direct](https://learn.microsoft.com/en-us/windows/win32/nativewifi/about-the-wi-fi-direct-api), [Windows Wi-Fi Direct APIs](https://learn.microsoft.com/en-us/uwp/api/windows.devices.wifidirect), [Windows BLE advertising](https://learn.microsoft.com/en-us/windows/uwp/devices-sensors/ble-beacon).
