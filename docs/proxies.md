# Security & Proxies

For production applications, you should **never** hardcode your VitalLens API key in your iOS app. If a malicious user extracts your key, they could consume your quota.

## Using a Proxy

The recommended approach is to route traffic through your own backend.

### 1. Configure the Client

Initialize `VitalLens` with `proxyURL` instead of `apiKey`.

```swift
let client = VitalLens(
    proxyURL: URL(string: "https://your-backend.com/api/vitallens"),
    method: "vitallens"
)
```

The client will now append `/resolve-model` and `/stream` to this base URL.

### 2. Implement the Backend

Your backend should forward the requests to `https://api.rouast.com/vitallens-v3`.

* **Forward Headers:** `Content-Type`, `X-Origin`, `X-Model`, `X-State`.
* **Add Header:** `x-api-key: YOUR_SECRET_KEY`.
* **Forward Body:** The raw binary body (for streaming) or JSON (for files).

See our [Node.js Proxy Example](https://github.com/Rouast-Labs/vitallens.js/blob/main/docs/proxies.md) for a reference implementation.
