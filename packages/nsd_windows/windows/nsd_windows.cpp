#include "nsd_windows.h"

#include "nsd_error.h"
#include "utilities.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <windows.h>

#include <iostream>
#include <memory>
#include <sstream>
#include <vector>

namespace nsd_windows {

	NsdWindows::NsdWindows(std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methodChannel, DnsApi api) : api(api) {
		dispatcher = std::make_shared<PlatformDispatcher>();
		this->methodChannel = std::move(methodChannel);
		this->methodChannel->SetMethodCallHandler(
			[nsdWindows = this](const auto& call, auto result) { nsdWindows->HandleMethodCall(call, result);
			});
		this->systemRequirementsSatisfied = CheckSystemRequirementsSatisfied();
	}

    NsdWindows::~NsdWindows() {
        methodChannel->SetMethodCallHandler(nullptr);
        dispatcher->Close();
        for (auto& entry : discoveryContextMap) api.BrowseCancel(&entry.second->canceller);
        for (auto& entry : resolveContextMap) {
            if (std::atomic_load(&entry.second->nativeLease)) api.ResolveCancel(&entry.second->canceller);
        }
        for (auto& entry : registerContextMap) {
            auto context = entry.second;
            if (context->unregistering) continue;
            if (context->instance) {
                std::atomic_store(&context->nativeLease, context);
                context->request.pRegisterCompletionCallback = &DnsServiceUnregisterCallback;
                const auto status = api.DeRegister(&context->request, nullptr);
                if (status != DNS_REQUEST_PENDING) std::atomic_store(&context->nativeLease, std::shared_ptr<RegisterContext>{});
            } else if (std::atomic_load(&context->nativeLease)) api.RegisterCancel(&context->canceller);
        }
    }

	void NsdWindows::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& methodCall,
		std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {

		const auto& method_name = methodCall.method_name();

		try {
			const auto& arguments = std::get<flutter::EncodableMap>(*methodCall.arguments());

			if (method_name == "startDiscovery") {
				StartDiscovery(arguments, result);
			}
			else if (method_name == "stopDiscovery") {
				StopDiscovery(arguments, result);
			}
			else if (method_name == "register") {
				Register(arguments, result);
			}
			else if (method_name == "resolve") {
				Resolve(arguments, result);
			}
			else if (method_name == "unregister") {
				Unregister(arguments, result);
			}
			else {
				result->NotImplemented();
			}
		}
		catch (const NsdError& e) {
			result->Error(ToErrorCode(e.errorCause), e.what());
		}
		catch (const std::exception& e) {
			result->Error(ToErrorCode(ErrorCause::INTERNAL_ERROR), e.what());
		}
	}

	void NsdWindows::StartDiscovery(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result)
	{
		if (!this->systemRequirementsSatisfied) {
			throw NsdError(ErrorCause::OPERATION_NOT_SUPPORTED, "Plugin requires at least Windows 10, build 18362");
		}

		auto handle = Deserialize<std::string>(arguments, "handle");
		auto serviceType = Deserialize<std::string>(arguments, "service.type");

		auto context = std::make_shared<DiscoveryContext>();
        context->dispatcher = dispatcher;
        std::atomic_store(&context->nativeLease, context);
		context->nsdWindows = this;
		context->handle = handle;

		auto queryName = ToUtf16(serviceType + ".local");

		DNS_SERVICE_BROWSE_REQUEST request{};
		request.Version = DNS_QUERY_REQUEST_VERSION1;
		request.InterfaceIndex = 0;
		request.QueryName = queryName.c_str();
		request.pBrowseCallback = &DnsServiceBrowseCallback;
		request.pQueryContext = context.get();

		auto status = api.Browse(&request, &context->canceller);

		if (status != DNS_REQUEST_PENDING) {
            std::atomic_store(&context->nativeLease, std::shared_ptr<DiscoveryContext>{});
			throw NsdError(ErrorCause::INTERNAL_ERROR, GetErrorMessage(status));
		}

		discoveryContextMap[handle] = std::move(context);
		methodChannel->InvokeMethod("onDiscoveryStartSuccessful", CreateMethodResult({ { "handle", handle } }));
		result->Success();
	}

	void NsdWindows::StopDiscovery(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result)
	{
		auto handle = Deserialize<std::string>(arguments, "handle");

		auto it = discoveryContextMap.find(handle);
		if (it == discoveryContextMap.end()) {
			throw NsdError(ErrorCause::ILLEGAL_ARGUMENT, "Unknown handle");
		}

		auto& context = *it->second.get();

		const auto status = api.BrowseCancel(&context.canceller);
		discoveryContextMap.erase(it);

		if (status != ERROR_SUCCESS) {
			throw NsdError(ErrorCause::INTERNAL_ERROR, GetErrorMessage(status));
		}

		methodChannel->InvokeMethod("onDiscoveryStopSuccessful", CreateMethodResult({ { "handle", handle } }));
		result->Success();
	}

	void NsdWindows::Resolve(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result)
	{
		auto handle = Deserialize<std::string>(arguments, "handle");
		auto serviceName = Deserialize<std::string>(arguments, "service.name");
		auto serviceType = Deserialize<std::string>(arguments, "service.type");

		auto context = std::make_shared<ResolveContext>();
        context->dispatcher = dispatcher;
        std::atomic_store(&context->nativeLease, context);
		context->nsdWindows = this;
		context->handle = handle;

		auto queryName = ToUtf16(serviceName + "." + serviceType + ".local");

		DNS_SERVICE_RESOLVE_REQUEST request{};
		request.Version = DNS_QUERY_REQUEST_VERSION1;
		request.InterfaceIndex = 0;
		request.QueryName = const_cast<PWSTR>(queryName.c_str());
		request.pResolveCompletionCallback = &DnsServiceResolveCallback;
		request.pQueryContext = context.get();

		const auto status = api.Resolve(&request, &context->canceller);

		if (status != DNS_REQUEST_PENDING) {
            std::atomic_store(&context->nativeLease, std::shared_ptr<ResolveContext>{});
			throw NsdError(ErrorCause::INTERNAL_ERROR, GetErrorMessage(status));
		}

		resolveContextMap[handle] = std::move(context);
		result->Success();
	}

	void NsdWindows::Register(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result)
	{
		if (!this->systemRequirementsSatisfied) {
			throw NsdError(ErrorCause::OPERATION_NOT_SUPPORTED, "Plugin requires at least Windows 10, build 18362");
		}

		auto handle = Deserialize<std::string>(arguments, "handle");
		auto serviceName = Deserialize<std::string>(arguments, "service.name");
		auto serviceType = Deserialize<std::string>(arguments, "service.type");
		auto servicePort = Deserialize<int>(arguments, "service.port");
		auto serviceTxt = FlutterTxtToWindowsTxt(DeserializeOptional<flutter::EncodableMap>(arguments, "service.txt"));

		auto computerName = GetComputerName();

		// see https://docs.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsserviceconstructinstance

		auto serviceNameW = ToUtf16(serviceName + "." + serviceType + ".local");
		auto hostNameW = computerName + L".local";

		PDNS_SERVICE_INSTANCE pServiceInstance = DnsServiceConstructInstance(
			serviceNameW.c_str(), // PCWSTR pServiceName
			hostNameW.c_str(), // PCWSTR pHostName
			nullptr, // PIP4_ADDRESS pIp4 (optional)
			nullptr, // PIP6_ADDRESS pIp6 (optional)
			static_cast<WORD>(servicePort), // WORD wPort
			0, // WORD wPriority
			0, // WORD wWeight
			serviceTxt->size, // DWORD dwPropertiesCount
			serviceTxt->pKeyPointers, // PCWSTR* keys
			serviceTxt->pValuePointers // PCWSTR* values
		);

		auto context = std::make_shared<RegisterContext>();
        context->dispatcher = dispatcher;
        std::atomic_store(&context->nativeLease, context);
		context->nsdWindows = this;
		context->handle = handle;

		auto& request = context->request;
		request.Version = DNS_QUERY_REQUEST_VERSION1;
		request.InterfaceIndex = 0;
		request.pServiceInstance = pServiceInstance;
		request.pRegisterCompletionCallback = &DnsServiceRegisterCallback;
		request.pQueryContext = context.get();
		request.unicastEnabled = false;

		auto status = api.Register(&request, &context->canceller);

		DnsServiceFreeInstance(request.pServiceInstance);
		request.pServiceInstance = nullptr; // will be replaced by OnServiceResolved()
		request.pRegisterCompletionCallback = nullptr; // will be replaced by Unregister()

		if (status != DNS_REQUEST_PENDING) {
            std::atomic_store(&context->nativeLease, std::shared_ptr<RegisterContext>{});
			throw NsdError(ErrorCause::INTERNAL_ERROR, GetErrorMessage(status));
		}

		registerContextMap[handle] = std::move(context);
		result->Success();
	}

	void NsdWindows::Unregister(const flutter::EncodableMap& arguments, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result)
	{
		auto handle = Deserialize<std::string>(arguments, "handle");

		auto it = registerContextMap.find(handle);
		if (it == registerContextMap.end()) {
			throw NsdError(ErrorCause::ILLEGAL_ARGUMENT, "Unknown handle");
		}

		auto& context = *it->second.get();
        if (context.unregistering) { result->Success(); return; }
        context.unregistering = true;
        std::atomic_store(&context.nativeLease, it->second);
		auto& request = context.request;

		request.pRegisterCompletionCallback = &DnsServiceUnregisterCallback; // set callback for request reuse

		auto status = api.DeRegister(&request, nullptr);


		if (status != DNS_REQUEST_PENDING) {
            std::atomic_store(&context.nativeLease, std::shared_ptr<RegisterContext>{});
            context.unregistering = false;
			throw NsdError(ErrorCause::INTERNAL_ERROR, GetErrorMessage(status));
		}

		result->Success();
	}

	void NsdWindows::OnServiceDiscovered(const std::string handle, const DWORD status, DnsRecords records)
	{
		//std::cout << GetTimeNow() << " " << "OnServiceDiscovered()" << std::endl;

		if (status != ERROR_SUCCESS) {
			//std::cout << GetTimeNow() << " " << "OnServiceDiscovered(): ERROR: " << GetErrorMessage(status) << std::endl;
			
			return;
		}

		auto serviceInfoO = GetServiceInfoFromRecords(records.get());
		if (!serviceInfoO.has_value()) {
			// must be deleted as described here: https://docs.microsoft.com/en-us/windows/win32/api/windns/nc-windns-dns_service_browse_callback
			
			return;
		}

		ServiceInfo& serviceInfo = serviceInfoO.value();
		auto discovery = discoveryContextMap.find(handle);
        if (discovery == discoveryContextMap.end()) return;
        std::vector<ServiceInfo>& services = discovery->second->services;

		auto it = FindIf(services, [compare = serviceInfo](ServiceInfo& current) -> bool {
			return
				current.name == compare.name &&
				current.type == compare.type;
			});

		if (serviceInfo.status == ServiceInfo::STATUS_FOUND) {

			if (it == services.end()) {
				services.push_back(serviceInfo);
				methodChannel->InvokeMethod("onServiceDiscovered", CreateMethodResult({
						{ "handle", handle },
						{ "service.name", serviceInfo.name.value() },
						{ "service.type", serviceInfo.type.value() },
					}));
			}
		}
		else {

			if (it != services.end()) {
				services.erase(it);
				methodChannel->InvokeMethod("onServiceLost", CreateMethodResult({
						{ "handle", handle },
						{ "service.name", serviceInfo.name.value() },
						{ "service.type", serviceInfo.type.value() },
					}));
			}
		}

		
	}

	void NsdWindows::OnServiceResolved(const std::string handle, const DWORD status, DnsInstance pInstance)
	{
		auto it = resolveContextMap.find(handle);
		if (it == resolveContextMap.end()) {
			//std::cout << "OnServiceResolved(): ERROR: Unknown handle: " << handle << std::endl;
			
			return;
		}

		if (status != ERROR_SUCCESS || !pInstance) {
            resolveContextMap.erase(it);
			methodChannel->InvokeMethod("onResolveFailed", CreateMethodResult({
					{ "handle", handle },
					{ "error.cause", ToErrorCode(ErrorCause::INTERNAL_ERROR) },
					{ "error.message", GetErrorMessage(status) },
				}));
			
			return;
		}

		auto components = Split(ToUtf8(pInstance->pszInstanceName), '.'); // "HP Color LaserJet MFP M277dw (C162F4)._http._tcp.local"
		auto serviceName = components.at(0);
		auto serviceType = components.at(1) + "." + components.at(2);
		auto servicePort = pInstance->wPort;
		auto serviceHost = ToUtf8(pInstance->pszHostName);
		auto serviceTxt = WindowsTxtToFlutterTxt(pInstance->dwPropertyCount, pInstance->keys, pInstance->values);

		
		resolveContextMap.erase(it);

		methodChannel->InvokeMethod("onResolveSuccessful", CreateMethodResult({
				{ "handle", handle },
				{ "service.type", serviceType },
				{ "service.name", serviceName },
				{ "service.port", servicePort },
				{ "service.host", serviceHost },
				{ "service.txt", serviceTxt },
			}));
	}

	bool NsdWindows::OnServiceRegistered(const std::string handle, const DWORD status, DnsInstance pInstance)
	{
		auto it = registerContextMap.find(handle);
		if (it == registerContextMap.end()) {
			//std::cout << "OnServiceRegistered(): ERROR: Unknown handle: " << handle << std::endl;
			
			return false;
		}

		auto& context = *it->second.get();
		auto& request = context.request;

		if (status != ERROR_SUCCESS || !pInstance) {
            registerContextMap.erase(it);
			
			methodChannel->InvokeMethod("onRegistrationFailed", CreateMethodResult({
					{ "handle", handle },
					{ "error.cause", ToErrorCode(ErrorCause::INTERNAL_ERROR) },
					{ "error.message", GetErrorMessage(status) },
				}));
			return false;
		}

		auto components = Split(ToUtf8(pInstance->pszInstanceName), '.'); // "HP Color LaserJet MFP M277dw (C162F4)._http._tcp.local"

		auto serviceName = components.at(0);
		auto serviceType = components.at(1) + "." + components.at(2);
		auto servicePort = pInstance->wPort;
		auto serviceHost = ToUtf8(pInstance->pszHostName);
		auto serviceTxt = WindowsTxtToFlutterTxt(pInstance->dwPropertyCount, pInstance->keys, pInstance->values);

		// the existing request must be reused with the newly received instance for unregistering 
		context.instance = pInstance;
        request.pServiceInstance = pInstance.get();

		methodChannel->InvokeMethod("onRegistrationSuccessful", CreateMethodResult({
				{ "handle", handle },
				{ "service.type", serviceType },
				{ "service.name", serviceName },
				{ "service.port", servicePort },
				{ "service.host", serviceHost },
				{ "service.txt", serviceTxt },
			}));
        return true;
	}

	void NsdWindows::OnServiceUnregistered(const std::string handle, const DWORD status, DnsInstance pInstance)
	{
		 // not used

		auto it = registerContextMap.find(handle);
		if (it == registerContextMap.end()) {
			//std::cout << "OnServiceUnregistered(): ERROR: Unknown handle: " << handle << std::endl;
			return;
		}

		registerContextMap.erase(it);

		if (status != ERROR_SUCCESS) {
			methodChannel->InvokeMethod("onUnregistrationFailed", CreateMethodResult({
					{ "handle", handle },
					{ "error.cause", ToErrorCode(ErrorCause::INTERNAL_ERROR) },
					{ "error.message", GetErrorMessage(status) },
				}));
			return;
		}

		methodChannel->InvokeMethod("onUnregistrationSuccessful", CreateMethodResult({ { "handle", handle } }));
	}

    namespace {
    DnsInstance OwnInstance(PDNS_SERVICE_INSTANCE value) {
        return DnsInstance(value, [](PDNS_SERVICE_INSTANCE p) { if (p) DnsServiceFreeInstance(p); });
    }
    // A registration can finish after the engine stops or while a queued result is dropped.
    // Remove that advertisement even though Flutter is no longer available to unregister it.
    struct OrphanRegistration {
        DnsInstance instance;
        DNS_SERVICE_REGISTER_REQUEST request{};
        static void Complete(DWORD, void* raw, PDNS_SERVICE_INSTANCE result) {
            auto owned = OwnInstance(result);
            delete static_cast<OrphanRegistration*>(raw);
        }
        static void Remove(DnsInstance instance) {
            auto* orphan = new OrphanRegistration;
            orphan->instance = std::move(instance);
            orphan->request.Version = DNS_QUERY_REQUEST_VERSION1;
            orphan->request.pServiceInstance = orphan->instance.get();
            orphan->request.pRegisterCompletionCallback = Complete;
            orphan->request.pQueryContext = orphan;
            if (DnsServiceDeRegister(&orphan->request, nullptr) != DNS_REQUEST_PENDING) delete orphan;
        }
    };
    struct RegistrationResult {
        DnsInstance instance;
        bool registered;
        bool adopted = false;
        ~RegistrationResult() { if (registered && !adopted && instance) OrphanRegistration::Remove(instance); }
    };
    }

    void NsdWindows::DnsServiceBrowseCallback(DWORD status, void* raw, PDNS_RECORD value) {
        auto context = std::atomic_load(&static_cast<DiscoveryContext*>(raw)->nativeLease);
        DnsRecords records(value, [](PDNS_RECORD p) { if (p) DnsRecordListFree(p, DnsFreeRecordList); });
        if (!context) return;
        context->dispatcher->Post([context, records, status] {
            context->nsdWindows->OnServiceDiscovered(context->handle, status, records);
        });
        if (status == ERROR_CANCELLED) std::atomic_store(&context->nativeLease, std::shared_ptr<DiscoveryContext>{});
    }

    void NsdWindows::DnsServiceResolveCallback(DWORD status, void* raw, PDNS_SERVICE_INSTANCE value) {
        auto context = std::atomic_exchange(&static_cast<ResolveContext*>(raw)->nativeLease, std::shared_ptr<ResolveContext>{});
        auto instance = OwnInstance(value);
        if (!context) return;
        context->dispatcher->Post([context, instance, status] {
            context->nsdWindows->OnServiceResolved(context->handle, status, instance);
        });
    }

    void NsdWindows::DnsServiceRegisterCallback(DWORD status, void* raw, PDNS_SERVICE_INSTANCE value) {
        auto context = std::atomic_exchange(&static_cast<RegisterContext*>(raw)->nativeLease, std::shared_ptr<RegisterContext>{});
        auto result = std::make_shared<RegistrationResult>();
        result->instance = OwnInstance(value);
        result->registered = status == ERROR_SUCCESS;
        if (!context) return;
        context->dispatcher->Post([context, result, status] {
            result->adopted = context->nsdWindows->OnServiceRegistered(context->handle, status, result->instance);
        });
    }

    void NsdWindows::DnsServiceUnregisterCallback(DWORD status, void* raw, PDNS_SERVICE_INSTANCE value) {
        auto context = std::atomic_exchange(&static_cast<RegisterContext*>(raw)->nativeLease, std::shared_ptr<RegisterContext>{});
        auto instance = OwnInstance(value);
        if (!context) return;
        context->dispatcher->Post([context, instance, status] {
            context->nsdWindows->OnServiceUnregistered(context->handle, status, instance);
        });
    }

	std::optional<ServiceInfo> NsdWindows::GetServiceInfoFromRecords(const PDNS_RECORD& records) {

		// record properties see https://docs.microsoft.com/en-us/windows/win32/api/windns/ns-windns-dns_recordw
		// seen: DNS_TYPE_A (0x0001), DNS_TYPE_TEXT (0x0010), DNS_TYPE_AAAA (0x001c), DNS_TYPE_SRV (0x0021)

		for (auto record = records; record; record = record->pNext) {
			if (record->wType == DNS_TYPE_PTR) { // 0x0012
				return GetServiceInfoFromPtrRecord(record);
			}
		}

		return std::nullopt;
	}

	std::optional<nsd_windows::ServiceInfo> NsdWindows::GetServiceInfoFromPtrRecord(const PDNS_RECORD& record)
	{
		auto nameHost = ToUtf8(record->Data.PTR.pNameHost); // PTR rdata field DNAME, e.g. "HP Color LaserJet MFP M277dw (C162F4)._http._tcp.local"
		auto ttl = record->dwTtl;

		auto components = Split(nameHost, '.');

		ServiceInfo serviceInfo;
		serviceInfo.name = components[0];
		serviceInfo.type = components[1] + "." + components[2];
		serviceInfo.status = (ttl > 0) ? ServiceInfo::STATUS_FOUND : ServiceInfo::STATUS_LOST;

		//std::cout << GetTimeNow() << " " << "Record: PTR: name: " << name << ", domain name: " << nameHost << ", ttl: " << ttl << std::endl;
		return serviceInfo;
	}

}  // namespace nsd_windows
