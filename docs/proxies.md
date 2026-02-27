# Security & Proxies

For production applications, you should **never** hardcode your VitalLens API key in your iOS app. If a malicious user extracts your key, they could consume your quota.

The recommended approach is to route traffic through your own backend proxy.

## 1. Configure the Client

Initialize `VitalLens` with `proxyURL` instead of `apiKey`.

```swift
let client = VitalLens(
    proxyURL: URL(string: "https://your-backend.com/api/vitallens"),
    method: "vitallens"
)
```

When `proxyURL` is set, the SDK **will not** attach an `X-Api-Key` header. It will append the necessary endpoint paths to your base URL automatically.

## 2. Implement the Backend

Your proxy must handle three specific endpoints and forward them to the VitalLens API (`https://api.rouast.com/vitallens-v3`).

For all requests, your proxy must:

1. Inject your secret API key via the `x-api-key` header.
2. Forward all `X-*` headers provided by the iOS client.
3. Return the exact JSON response back to the client.

### Endpoints to Handle

1. GET `/resolve-model`
    - **Purpose:** Determines the optimal model config for your plan.
    - **Query Params:** Forward any query parameters (e.g., `?model=vitallens-2.0`).
2. POST `/stream`
    - **Purpose:** Processes live camera frames in real-time.
    - **Headers to Forward:** `Content-Type: application/octet-stream`, `X-Origin`, `X-Encoding`, `X-Model`, `X-State`.
    - **Body:** Forward the raw binary body exactly as received (the iOS client compresses it using gzip).
3. POST `/file`
    - **Purpose:** Processes pre-recorded video files.
    - **Headers to Forward:** `Content-Type: application/json`.
    - **Body:** Forward the JSON payload exactly as received (contains Base64 encoded video and state).

### Example Reference

If you are using Node.js for your backend, you can see a reference proxy implementation in our [JavaScript repository documentation](https://github.com/Rouast-Labs/vitallens.js/blob/main/docs/proxies.md).
