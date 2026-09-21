#pragma once

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windns.h>

#include <memory>
#include <atomic>
#include <type_traits>
#include "platform_dispatcher.h"

#pragma warning(disable : 4458) // declaration hides class member (used intentionally in method parameters vs local variables)
#pragma comment(lib, "dnsapi.lib")


namespace nsd_windows {

	class NsdWindows;
    struct DnsApi {
        decltype(&DnsServiceBrowse) Browse = &DnsServiceBrowse;
        decltype(&DnsServiceBrowseCancel) BrowseCancel = &DnsServiceBrowseCancel;
        decltype(&DnsServiceResolve) Resolve = &DnsServiceResolve;
        decltype(&DnsServiceResolveCancel) ResolveCancel = &DnsServiceResolveCancel;
        decltype(&DnsServiceRegister) Register = &DnsServiceRegister;
        decltype(&DnsServiceRegisterCancel) RegisterCancel = &DnsServiceRegisterCancel;
        decltype(&DnsServiceDeRegister) DeRegister = &DnsServiceDeRegister;
    };
    using DnsInstance = std::shared_ptr<DNS_SERVICE_INSTANCE>;
    using DnsRecords = std::shared_ptr<std::remove_pointer_t<PDNS_RECORD>>;
    template <class T> struct AsyncContext {
        NsdWindows* nsdWindows = nullptr;
        std::shared_ptr<PlatformDispatcher> dispatcher;
        // Native cancellation is asynchronous. Keep the context until the final callback.
        std::shared_ptr<T> nativeLease;
        std::string handle;
        DNS_SERVICE_CANCEL canceller{};
    };

	struct ServiceInfo {

		enum Status {
			STATUS_FOUND,
			STATUS_LOST
		};

		std::optional<std::string> name;
		std::optional<std::string> type;
		std::optional<std::string> host;
		std::optional<int> port;
		Status status;
	};


	struct DiscoveryContext : AsyncContext<DiscoveryContext> {

		std::vector<ServiceInfo> services;
	};


	struct ResolveContext : AsyncContext<ResolveContext> {

	};

	struct RegisterContext : AsyncContext<RegisterContext> {

		DNS_SERVICE_REGISTER_REQUEST request{};
        DnsInstance instance;
        bool unregistering = false;
	};

	class NsdWindows {
	public:

		static void DnsServiceBrowseCallback(const DWORD status, LPVOID context, PDNS_RECORD records);
		static void DnsServiceRegisterCallback(const DWORD status, LPVOID context, PDNS_SERVICE_INSTANCE pInstance);
		static void DnsServiceUnregisterCallback(const DWORD status, LPVOID context, PDNS_SERVICE_INSTANCE pInstance);
		static void DnsServiceResolveCallback(const DWORD status, LPVOID context, PDNS_SERVICE_INSTANCE pInstance);

		NsdWindows(std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methodChannel, DnsApi api = {});
		virtual ~NsdWindows();

		NsdWindows(const NsdWindows&) = delete; // disallow copy
		NsdWindows& operator=(const NsdWindows&) = delete; // disallow assign

		void OnServiceDiscovered(const std::string handle, const DWORD status, DnsRecords records);
		void OnServiceResolved(const std::string handle, const DWORD status, DnsInstance pInstance);
		bool OnServiceRegistered(const std::string handle, const DWORD status, DnsInstance pInstance);
		void OnServiceUnregistered(const std::string handle, const DWORD status, DnsInstance pInstance);

	private:

		static std::optional<ServiceInfo> GetServiceInfoFromRecords(const PDNS_RECORD& records);
		static std::optional<ServiceInfo> GetServiceInfoFromPtrRecord(const PDNS_RECORD& record);

		std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methodChannel;
		std::map<std::string, std::shared_ptr<DiscoveryContext>> discoveryContextMap;
		std::map<std::string, std::shared_ptr<RegisterContext>> registerContextMap;
		std::map<std::string, std::shared_ptr<ResolveContext>> resolveContextMap;

		bool systemRequirementsSatisfied;
        DnsApi api;
        std::shared_ptr<PlatformDispatcher> dispatcher;

		void HandleMethodCall(
			const flutter::MethodCall<flutter::EncodableValue>& method_call,
			std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);

		void StartDiscovery(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
		void StopDiscovery(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
		void Resolve(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
		void Register(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);
		void Unregister(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);

	};

}  // namespace nsd_windows
