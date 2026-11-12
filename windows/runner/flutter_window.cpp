#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <cwctype>
#include <filesystem>
#include <iterator>
#include <memory>
#include <mutex>
#include <shlobj.h>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>
#include <wlanapi.h>
#include <wincred.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.WiFiDirect.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/base.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
winrt::Windows::Devices::WiFiDirect::WiFiDirectDevice active_direct_device{nullptr};

struct DirectDiscoveryState {
  std::mutex mutex;
  std::condition_variable changed;
  std::unordered_set<std::string> seen_ids;
  std::vector<flutter::EncodableValue> devices;
};
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  direct_radio_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.omnidrop/direct_radio",
      &flutter::StandardMethodCodec::GetInstance());
  direct_radio_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "discoverDirectDevices") {
          std::thread([result = std::move(result)]() mutable {
            bool apartment_initialized = false;
            try {
              winrt::init_apartment(winrt::apartment_type::multi_threaded);
              apartment_initialized = true;
              const auto selector = winrt::Windows::Devices::WiFiDirect::WiFiDirectDevice::GetDeviceSelector(
                  winrt::Windows::Devices::WiFiDirect::WiFiDirectDeviceSelectorType::AssociationEndpoint);
              auto state = std::make_shared<DirectDiscoveryState>();
              auto watcher = winrt::Windows::Devices::Enumeration::DeviceInformation::CreateWatcher(selector);
              const auto added_token = watcher.Added([state](
                  const winrt::Windows::Devices::Enumeration::DeviceWatcher&,
                  const winrt::Windows::Devices::Enumeration::DeviceInformation& device) {
                try {
                  const auto id = winrt::to_string(device.Id());
                  const auto name = winrt::to_string(device.Name());
                  {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    if (!state->seen_ids.insert(id).second) return;
                    state->devices.emplace_back(flutter::EncodableMap{
                        {flutter::EncodableValue("id"), flutter::EncodableValue(id)},
                        {flutter::EncodableValue("name"), flutter::EncodableValue(name.empty() ? "Wi-Fi Direct device" : name)},
                    });
                  }
                  state->changed.notify_all();
                } catch (...) {
                  // Ignore malformed device records and keep the watcher alive.
                }
              });
              watcher.Start();
              std::vector<flutter::EncodableValue> found;
              {
                std::unique_lock<std::mutex> lock(state->mutex);
                const bool discovered = state->changed.wait_for(
                    lock, std::chrono::seconds(12), [&state] { return !state->devices.empty(); });
                if (discovered) state->changed.wait_for(lock, std::chrono::milliseconds(750));
                found = state->devices;
              }
              watcher.Stop();
              watcher.Added(added_token);
              result->Success(flutter::EncodableValue(std::move(found)));
            } catch (const winrt::hresult_error& error) {
              result->Error("DIRECT_DISCOVERY_FAILED", winrt::to_string(error.message()));
            } catch (const std::exception& error) {
              result->Error("DIRECT_DISCOVERY_FAILED", error.what());
            }
            if (apartment_initialized) winrt::uninit_apartment();
          }).detach();
          return;
        }
        if (call.method_name() == "connectDirectDevice") {
          const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("INVALID_DEVICE", "Choose a Wi-Fi Direct device first.");
            return;
          }
          const auto id_entry = arguments->find(flutter::EncodableValue("id"));
          if (id_entry == arguments->end() || !std::holds_alternative<std::string>(id_entry->second)) {
            result->Error("INVALID_DEVICE", "Choose a Wi-Fi Direct device first.");
            return;
          }
          try {
            const auto id = winrt::to_hstring(std::get<std::string>(id_entry->second));
            active_direct_device = winrt::Windows::Devices::WiFiDirect::WiFiDirectDevice::FromIdAsync(id).get();
            if (!active_direct_device) {
              result->Error("DIRECT_CONNECT_FAILED", "Windows could not connect to this Wi-Fi Direct device.");
              return;
            }
            const auto pairs = active_direct_device.GetConnectionEndpointPairs();
            if (pairs.Size() == 0) {
              result->Error("DIRECT_ENDPOINT_MISSING", "Wi-Fi Direct connected without a socket endpoint.");
              return;
            }
            const auto address = winrt::to_string(pairs.GetAt(0).RemoteHostName().RawName());
            result->Success(flutter::EncodableValue(address));
          } catch (const winrt::hresult_error& error) {
            result->Error("DIRECT_CONNECT_FAILED", winrt::to_string(error.message()));
          }
          return;
        }
        if (call.method_name() == "stopDirectDevice") {
          if (active_direct_device) {
            active_direct_device.Close();
            active_direct_device = nullptr;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "getNetworkBand") {
          std::string band = "unknown";
          HANDLE client_handle = nullptr;
          DWORD negotiated_version = 0;
          if (WlanOpenHandle(2, nullptr, &negotiated_version, &client_handle) == ERROR_SUCCESS) {
            PWLAN_INTERFACE_INFO_LIST interfaces = nullptr;
            if (WlanEnumInterfaces(client_handle, nullptr, &interfaces) == ERROR_SUCCESS && interfaces != nullptr) {
              for (DWORD i = 0; i < interfaces->dwNumberOfItems; ++i) {
                const auto& interface_info = interfaces->InterfaceInfo[i];
                if (interface_info.isState != wlan_interface_state_connected) continue;
                DWORD connection_size = 0;
                PVOID connection_data = nullptr;
                if (WlanQueryInterface(client_handle, &interface_info.InterfaceGuid,
                                       wlan_intf_opcode_current_connection, nullptr,
                                       &connection_size, &connection_data, nullptr) == ERROR_SUCCESS &&
                    connection_data != nullptr && connection_size >= sizeof(WLAN_CONNECTION_ATTRIBUTES)) {
                  auto* connection = static_cast<WLAN_CONNECTION_ATTRIBUTES*>(connection_data);
                  PWLAN_BSS_LIST networks = nullptr;
                  if (WlanGetNetworkBssList(client_handle, &interface_info.InterfaceGuid,
                                            &connection->wlanAssociationAttributes.dot11Ssid,
                                            connection->wlanAssociationAttributes.dot11BssType,
                                            FALSE, nullptr, &networks) == ERROR_SUCCESS && networks != nullptr) {
                    for (DWORD network_index = 0; network_index < networks->dwNumberOfItems; ++network_index) {
                      const auto& network = networks->wlanBssEntries[network_index];
                      if (std::equal(std::begin(network.dot11Bssid), std::end(network.dot11Bssid),
                                     std::begin(connection->wlanAssociationAttributes.dot11Bssid))) {
                        const auto mhz = network.ulChCenterFrequency / 1000;
                        band = mhz >= 2400 && mhz < 2500 ? "2.4 GHz"
                             : mhz >= 4900 && mhz < 5925 ? "5 GHz"
                             : mhz >= 5925 && mhz <= 7125 ? "6 GHz" : "unknown";
                        break;
                      }
                    }
                    WlanFreeMemory(networks);
                  }
                  WlanFreeMemory(connection_data);
                  if (band != "unknown") break;
                } else if (connection_data != nullptr) {
                  WlanFreeMemory(connection_data);
                }
                DWORD data_size = 0;
                PVOID channel_data = nullptr;
                if (WlanQueryInterface(client_handle, &interface_info.InterfaceGuid,
                                       wlan_intf_opcode_channel_number, nullptr,
                                       &data_size, &channel_data, nullptr) == ERROR_SUCCESS &&
                    channel_data != nullptr && data_size >= sizeof(ULONG)) {
                  const auto channel = *static_cast<ULONG*>(channel_data);
                  band = channel >= 32 && channel <= 177 ? "5 GHz" : "unknown";
                  WlanFreeMemory(channel_data);
                  break;
                }
                if (channel_data != nullptr) WlanFreeMemory(channel_data);
              }
              WlanFreeMemory(interfaces);
            }
            WlanCloseHandle(client_handle, nullptr);
          }
          result->Success(flutter::EncodableValue(band));
          return;
        }
        if (call.method_name() == "getDefaultDownloadFolder") {
          PWSTR downloads_path = nullptr;
          const auto status = SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_CREATE,
                                                   nullptr, &downloads_path);
          if (FAILED(status) || downloads_path == nullptr) {
            result->Error("DOWNLOAD_FOLDER", "Could not locate the Downloads folder.");
            return;
          }
          std::filesystem::path folder(downloads_path);
          CoTaskMemFree(downloads_path);
          folder /= L"OmniDrop";
          std::error_code error;
          std::filesystem::create_directories(folder, error);
          if (error) {
            result->Error("DOWNLOAD_FOLDER", "Could not create Downloads\\OmniDrop.");
          } else {
            result->Success(flutter::EncodableValue(folder.string()));
          }
          return;
        }
        if (call.method_name() != "getCapabilities") {
          result->NotImplemented();
          return;
        }

        DWORD negotiated_version = 0;
        HANDLE client_handle = nullptr;
        const DWORD wfd_status = WFDOpenHandle(WFD_API_VERSION, &negotiated_version, &client_handle);
        const bool wifi_direct_supported = wfd_status == ERROR_SUCCESS;
        if (wifi_direct_supported) {
          WFDCloseHandle(client_handle);
        }

        bool ble_supported = false;
        bool ble_available = false;
        try {
          const auto adapter = winrt::Windows::Devices::Bluetooth::BluetoothAdapter::GetDefaultAsync().get();
          ble_supported = adapter && adapter.IsLowEnergySupported();
          ble_available = ble_supported && adapter.IsCentralRoleSupported();
        } catch (const winrt::hresult_error&) {
          ble_supported = false;
        }

        auto capability = [](std::string name, std::string support, std::string message) {
          return flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("name"), flutter::EncodableValue(std::move(name))},
              {flutter::EncodableValue("support"), flutter::EncodableValue(std::move(support))},
              {flutter::EncodableValue("message"), flutter::EncodableValue(std::move(message))},
          });
        };

        std::vector<flutter::EncodableValue> capabilities;
        capabilities.push_back(capability(
            "Wi-Fi Direct",
            wifi_direct_supported ? "supported" : "unsupported",
            wifi_direct_supported
                ? "Windows exposes Wi-Fi Direct. This desktop app may require Windows device pairing before opening a direct session."
                : "Windows could not open its Wi-Fi Direct service. Check the Wi-Fi adapter, driver, and whether Mobile Hotspot is active."));
        capabilities.push_back(capability(
            "Bluetooth Low Energy",
            !ble_supported ? "unsupported" : (ble_available ? "supported" : "unavailable"),
            !ble_supported
                ? "No Bluetooth LE adapter was detected."
                : (ble_available ? "Bluetooth LE is available for nearby discovery."
                                 : "Bluetooth LE is supported, but this adapter cannot act as a scanner.")));
        capabilities.push_back(capability(
            "Wi-Fi Aware (NAN)", "unsupported",
            "Wi-Fi Aware is not exposed by the Windows desktop radio APIs."));
        result->Success(flutter::EncodableValue(std::move(capabilities)));
      });
  auto secure_store_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.omnidrop/secure_store",
      &flutter::StandardMethodCodec::GetInstance());
  secure_store_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("INVALID_ARGUMENTS", "Secure store arguments are missing.");
          return;
        }
        const auto key_entry = arguments->find(flutter::EncodableValue("key"));
        if (key_entry == arguments->end() || !std::holds_alternative<std::string>(key_entry->second)) {
          result->Error("INVALID_KEY", "Secure store key is missing.");
          return;
        }
        const auto key = std::get<std::string>(key_entry->second);
        const bool valid_key = !key.empty() && key.size() <= 128 && std::all_of(
            key.begin(), key.end(), [](unsigned char value) {
              return std::isalnum(value) || value == '_' || value == '-';
            });
        if (!valid_key) {
          result->Error("INVALID_KEY", "Secure store key contains unsupported characters.");
          return;
        }
        const std::wstring target_name = L"OmniDrop:" + std::wstring(key.begin(), key.end());

        if (call.method_name() == "write") {
          const auto value_entry = arguments->find(flutter::EncodableValue("value"));
          if (value_entry == arguments->end() || !std::holds_alternative<std::string>(value_entry->second)) {
            result->Error("INVALID_VALUE", "Secure store value is missing.");
            return;
          }
          const auto& value = std::get<std::string>(value_entry->second);
          CREDENTIALW credential{};
          credential.Type = CRED_TYPE_GENERIC;
          credential.TargetName = const_cast<LPWSTR>(target_name.c_str());
          credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
          credential.UserName = const_cast<LPWSTR>(L"OmniDrop");
          credential.CredentialBlobSize = static_cast<DWORD>(value.size());
          credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char*>(value.data()));
          if (!CredWriteW(&credential, 0)) {
            result->Error("SECURE_STORE_FAILED", "Windows Credential Manager could not save this pairing key.");
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "read") {
          PCREDENTIALW credential = nullptr;
          if (!CredReadW(target_name.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
            if (GetLastError() == ERROR_NOT_FOUND) {
              result->Success(flutter::EncodableValue());
            } else {
              result->Error("SECURE_STORE_FAILED", "Windows Credential Manager could not read this pairing key.");
            }
            return;
          }
          const std::string value(reinterpret_cast<const char*>(credential->CredentialBlob), credential->CredentialBlobSize);
          CredFree(credential);
          result->Success(flutter::EncodableValue(value));
          return;
        }

        if (call.method_name() == "delete") {
          if (!CredDeleteW(target_name.c_str(), CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND) {
            result->Error("SECURE_STORE_FAILED", "Windows Credential Manager could not remove this pairing key.");
            return;
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  secure_store_channel_ = std::move(secure_store_channel);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (active_direct_device) {
    active_direct_device.Close();
    active_direct_device = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
