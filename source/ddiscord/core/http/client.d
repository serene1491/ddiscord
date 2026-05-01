/**
 * ddiscord — real HTTP client wrapper for Discord REST.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.core.http.client;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import ddiscord.util.errors : formatError;
import ddiscord.util.identity : DdiscordUserAgent;
import ddiscord.util.limits : DiscordApiBase;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import requests.base : RequestException, Response;
import requests.request : Request;
import requests.streams : ConnectError, TimeoutException;
import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.datetime : Duration, dur;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

version (Posix)
{
    import core.sys.posix.signal : SIGPIPE, SIG_IGN, signal;
}

version (Posix)
shared static this()
{
    // Prevent process-wide termination on socket writes to a peer that already closed.
    // The HTTP layer will surface the failure as a regular transport error instead.
    signal(SIGPIPE, SIG_IGN);
}

/// Supported HTTP verbs for Discord REST.
enum HttpMethod
{
    Get,
    Post,
    Put,
    Patch,
    Delete,
}

/// A low-level HTTP request.
struct HttpRequest
{
    HttpMethod method = HttpMethod.Get;
    string url;
    string[string] headers;
    ubyte[] body;
    string contentType = "application/json";
    bool authenticated = true;
}

/// A low-level HTTP response.
struct HttpResponse
{
    ushort statusCode;
    string[string] headers;
    ubyte[] body;

    /// Returns the body as text.
    string text() const @property
    {
        return cast(string) body;
    }

    /// Returns whether the status code is successful.
    bool isSuccess() const @property
    {
        return statusCode >= 200 && statusCode < 300;
    }

    /// Parses the body as JSON.
    Result!(JSONValue, string) json() const
    {
        if (body.length == 0)
            return Result!(JSONValue, string).err("Response body was empty.");

        try
        {
            return Result!(JSONValue, string).ok(parseJSON(text));
        }
        catch (Exception e)
        {
            return Result!(JSONValue, string).err("Response body was not valid JSON: " ~ e.msg);
        }
    }
}

/// The category of an HTTP failure.
enum HttpErrorKind
{
    Configuration,
    Transport,
    Timeout,
    Authentication,
    Forbidden,
    NotFound,
    RateLimited,
    Server,
    InvalidResponse,
    UnexpectedStatus,
}

/// A structured HTTP error with actionable details.
struct HttpError
{
    HttpErrorKind kind;
    string message;
    string hint;
    string method;
    string url;
    ushort statusCode;
    string responseBody;
    string[string] headers;
    Nullable!Duration retryAfter;
}

/// A transport hook used for testing.
alias HttpTransport = Result!(HttpResponse, HttpError) delegate(HttpRequest request);

/// Runtime HTTP configuration.
struct HttpClientConfig
{
    string baseUrl = DiscordApiBase;
    string token;
    string userAgent = DdiscordUserAgent;
    Duration timeout;
    size_t sessionPoolSize = 2;
    bool autoRetryRateLimits = true;
    uint maxRateLimitRetries = 3;
    bool autoRetryServerErrors = true;
    uint maxServerErrorRetries = 3;
    Duration retryBaseDelay = dur!"msecs"(500);
    Duration maxRetryDelay = dur!"seconds"(30);
    string[string] defaultHeaders;
    Nullable!HttpTransport transport;
}

/// Blocking HTTP client with Discord-specific defaults.
final class HttpClient
{
    private final class SessionSlot
    {
        Mutex mutex;
        Request request;

        this()
        {
            mutex = new Mutex;
        }
    }

    private HttpClientConfig _config;
    private Mutex _poolMutex;
    private SessionSlot[] _sessions;
    private size_t _nextSessionIndex;

    this(HttpClientConfig config = HttpClientConfig.init)
    {
        _config = config;
        _poolMutex = new Mutex;

        auto poolSize = config.sessionPoolSize == 0 ? 1 : config.sessionPoolSize;
        _sessions.length = poolSize;
        foreach (index; 0 .. poolSize)
        {
            _sessions[index] = new SessionSlot;
            resetRequestSession(_sessions[index]);
        }
    }

    /// Executes a request and returns either a response or a structured error.
    Result!(HttpResponse, HttpError) send(HttpRequest request)
    {
        auto prepared = prepare(request);
        if (prepared.isErr)
            return Result!(HttpResponse, HttpError).err(prepared.error);

        return sendWithRetry(prepared.value);
    }

    private Result!(HttpResponse, HttpError) sendWithRetry(HttpRequest request)
    {
        uint rateLimitRetries;
        uint serverErrorRetries;
        auto retryDelay = _config.retryBaseDelay;

        while (true)
        {
            auto response = executeWithConfiguredTransport(request);
            if (response.isOk)
                return response;

            auto error = response.error;

            if (
                _config.autoRetryRateLimits &&
                error.kind == HttpErrorKind.RateLimited &&
                rateLimitRetries < _config.maxRateLimitRetries
            )
            {
                rateLimitRetries++;
                auto waitTime = error.retryAfter.getOr(_config.retryBaseDelay);
                sleepFor(waitTime);
                continue;
            }

            if (
                _config.autoRetryServerErrors &&
                isRetryableFailure(error.kind) &&
                serverErrorRetries < _config.maxServerErrorRetries
            )
            {
                serverErrorRetries++;
                sleepFor(retryDelay);
                retryDelay = nextRetryDelay(retryDelay, _config.maxRetryDelay);
                continue;
            }

            return response;
        }
    }

    private Result!(HttpResponse, HttpError) executeWithConfiguredTransport(HttpRequest request)
    {
        if (!_config.transport.isNull)
        {
            auto transport = _config.transport.get;
            return transport(request);
        }

        return execute(request);
    }

    private Result!(HttpRequest, HttpError) prepare(HttpRequest request)
    {
        if (request.url.length == 0)
        {
            return Result!(HttpRequest, HttpError).err(httpError(
                HttpErrorKind.Configuration,
                "HTTP request URL was empty.",
                request,
                "Pass either an absolute URL or a route path."
            ));
        }

        if (!request.url.canFind("://"))
        {
            auto base = _config.baseUrl.length == 0 ? DiscordApiBase : _config.baseUrl;
            request.url = joinUrl(base, request.url);
        }

        auto headers = _config.defaultHeaders.dup;
        foreach (key, value; request.headers)
            headers[key] = value;

        if (!headerExists(headers, "User-Agent"))
            headers["User-Agent"] = _config.userAgent;

        if (request.authenticated)
        {
            if (_config.token.length == 0)
            {
                return Result!(HttpRequest, HttpError).err(httpError(
                    HttpErrorKind.Configuration,
                    "This request requires a Discord bot token, but no token was configured.",
                    request,
                    "Set `ClientConfig.token` or `RestClientConfig.token` before calling Discord REST APIs."
                ));
            }

            if (!headerExists(headers, "Authorization"))
                headers["Authorization"] = normalizeAuthorization(_config.token);
        }

        if (request.body.length != 0 && request.contentType.length != 0 && !headerExists(headers, "Content-Type"))
            headers["Content-Type"] = request.contentType;

        request.headers = headers;
        return Result!(HttpRequest, HttpError).ok(request);
    }

    private Result!(HttpResponse, HttpError) execute(HttpRequest request)
    {
        auto slot = checkoutSession();

        synchronized (slot.mutex)
        {
            if (_config.timeout != Duration.init)
                slot.request.timeout = _config.timeout;

            slot.request.keepAlive = true;
            slot.request.clearHeaders();
            slot.request.addHeaders(request.headers);

            try
            {
                Response response;

                final switch (request.method)
                {
                    case HttpMethod.Get:
                        response = slot.request.get(request.url);
                        break;
                    case HttpMethod.Post:
                        response = slot.request.exec!"POST"(request.url, request.body, request.contentType);
                        break;
                    case HttpMethod.Put:
                        response = slot.request.exec!"PUT"(request.url, request.body, request.contentType);
                        break;
                    case HttpMethod.Patch:
                        response = slot.request.exec!"PATCH"(request.url, request.body, request.contentType);
                        break;
                    case HttpMethod.Delete:
                        if (request.body.length == 0)
                            response = slot.request.exec!"DELETE"(request.url);
                        else
                            response = slot.request.exec!"DELETE"(request.url, request.body, request.contentType);
                        break;
                }

                HttpResponse converted;
                converted.statusCode = response.code;
                converted.body = response.responseBody.data.dup;

                foreach (key, value; response.responseHeaders)
                    converted.headers[normalizeHeaderName(key)] = value;

                if (!converted.isSuccess)
                    return Result!(HttpResponse, HttpError).err(statusError(request, converted));

                return Result!(HttpResponse, HttpError).ok(converted);
            }
            catch (TimeoutException e)
            {
                resetRequestSession(slot);
                return Result!(HttpResponse, HttpError).err(httpError(
                    HttpErrorKind.Timeout,
                    "HTTP request to Discord timed out.",
                    request,
                    "Check your network connection, increase the timeout, or retry after a short delay.",
                    e.msg
                ));
            }
            catch (ConnectError e)
            {
                resetRequestSession(slot);
                return Result!(HttpResponse, HttpError).err(httpError(
                    HttpErrorKind.Transport,
                    "Could not connect to the Discord API.",
                    request,
                    "Check DNS, outbound network access, proxy settings, or Discord availability.",
                    e.msg
                ));
            }
            catch (RequestException e)
            {
                resetRequestSession(slot);
                return Result!(HttpResponse, HttpError).err(requestExceptionError(request, e));
            }
            catch (Exception e)
            {
                resetRequestSession(slot);
                return Result!(HttpResponse, HttpError).err(httpError(
                    HttpErrorKind.Transport,
                    "An unexpected HTTP client failure occurred.",
                    request,
                    "This usually indicates a local networking issue or malformed request configuration.",
                    e.msg
                ));
            }
        }
    }

    private SessionSlot checkoutSession()
    {
        synchronized (_poolMutex)
        {
            auto slot = _sessions[_nextSessionIndex % _sessions.length];
            _nextSessionIndex++;
            return slot;
        }
    }

    private void resetRequestSession(SessionSlot slot)
    {
        slot.request = Request();
        slot.request.keepAlive = true;
        if (_config.timeout != Duration.init)
            slot.request.timeout = _config.timeout;
    }

    private HttpError statusError(HttpRequest request, HttpResponse response)
    {
        auto body = response.text;
        return statusErrorForCode(request, response.statusCode, body, response.headers);
    }
}

private HttpError statusErrorForCode(
    HttpRequest request,
    ushort statusCode,
    string body,
    string[string] headers = null
)
{
    if (statusCode == 401)
    {
        return httpError(
            HttpErrorKind.Authentication,
            "Discord rejected the request because the bot token was invalid or missing required authentication.",
            request,
            "Ensure the token is correct and includes the `Bot ` prefix only once.",
            body,
            statusCode,
            headers
        );
    }

    if (statusCode == 403)
    {
        return httpError(
            HttpErrorKind.Forbidden,
            "Discord refused the request because the bot lacks permission for this action.",
            request,
            "Verify the bot's guild permissions, channel overwrites, and application scopes.",
            body,
            statusCode,
            headers
        );
    }

    if (statusCode == 404)
    {
        return httpError(
            HttpErrorKind.NotFound,
            "Discord could not find the requested resource.",
            request,
            "Double-check IDs such as channel, message, interaction, or application identifiers.",
            body,
            statusCode,
            headers
        );
    }

    if (statusCode == 422)
    {
        return httpError(
            HttpErrorKind.UnexpectedStatus,
            "Discord rejected the request payload as semantically invalid.",
            request,
            "Inspect the API error detail and adjust payload fields such as components, options, or attachments.",
            body,
            statusCode,
            headers
        );
    }

    if (statusCode == 429)
    {
        auto retryAfter = parseRetryAfter(headers, body);
        return httpError(
            HttpErrorKind.RateLimited,
            "Discord rate limited the request.",
            request,
            "Respect `Retry-After` and `X-RateLimit-*` headers before retrying.",
            body,
            statusCode,
            headers,
            retryAfter
        );
    }

    if (statusCode >= 500)
    {
        return httpError(
            HttpErrorKind.Server,
            "Discord returned a server-side error.",
            request,
            "Retry with backoff. If the problem persists, Discord may be degraded.",
            body,
            statusCode,
            headers
        );
    }

    return httpError(
        HttpErrorKind.UnexpectedStatus,
        "Discord returned an unexpected HTTP status code.",
        request,
        "Inspect the response body and headers for Discord's error details.",
        body,
        statusCode,
        headers
    );
}

private HttpError requestExceptionError(HttpRequest request, RequestException error)
{
    auto detail = transportExceptionDetail(error);
    auto statusCode = parseStatusCodeFromExceptionMessage(detail);

    if (!statusCode.isNull)
    {
        auto payload = extractJsonPayloadFromTransportDetail(detail);
        auto body = payload.isNull ? detail : payload.get;
        return statusErrorForCode(request, statusCode.get, body);
    }

    return httpError(
        HttpErrorKind.Transport,
        "The HTTP client failed while talking to Discord.",
        request,
        "Inspect the nested error detail for transport-specific information.",
        detail
    );
}

private string transportExceptionDetail(Exception error)
{
    auto detail = error.msg.strip;
    if (detail.length != 0)
        return detail;
    return typeid(error).name ~ " without additional message detail.";
}

private Nullable!ushort parseStatusCodeFromExceptionMessage(string detail)
{
    auto lowered = asciiLowercase(detail);
    if (lowered.length < 3)
        return Nullable!ushort.init;

    static immutable markers = [
        "status code ",
        "status ",
        "http ",
        "http/",
    ];

    foreach (index; 0 .. lowered.length)
    {
        foreach (marker; markers)
        {
            if (!startsWithAt(lowered, marker, index))
                continue;

            auto parsed = parseStatusCodeAt(lowered, index + marker.length);
            if (!parsed.isNull)
                return parsed;
        }
    }

    return Nullable!ushort.init;
}

private Nullable!string extractJsonPayloadFromTransportDetail(string detail)
{
    ptrdiff_t open = -1;
    ptrdiff_t close = -1;

    foreach (index, ch; detail)
    {
        if (ch == '{' && open == -1)
            open = cast(ptrdiff_t) index;
        if (ch == '}')
            close = cast(ptrdiff_t) index;
    }

    if (open == -1 || close == -1 || close <= open)
        return Nullable!string.init;

    auto candidate = detail[open .. close + 1].strip;
    if (candidate.length == 0)
        return Nullable!string.init;
    return Nullable!string.of(candidate);
}

private Nullable!ushort parseStatusCodeAt(string text, size_t start)
{
    auto index = start;
    while (index < text.length && text[index] == ' ')
        index++;

    if (index + 3 > text.length)
        return Nullable!ushort.init;
    if (!isAsciiDigit(text[index]) || !isAsciiDigit(text[index + 1]) || !isAsciiDigit(text[index + 2]))
        return Nullable!ushort.init;
    if (index + 3 < text.length && isAsciiDigit(text[index + 3]))
        return Nullable!ushort.init;

    auto value = (text[index] - '0') * 100 + (text[index + 1] - '0') * 10 + (text[index + 2] - '0');
    if (value < 100 || value > 599)
        return Nullable!ushort.init;
    return Nullable!ushort.of(cast(ushort) value);
}

private bool startsWithAt(string text, string prefix, size_t index)
{
    if (index + prefix.length > text.length)
        return false;
    return text[index .. index + prefix.length] == prefix;
}

private string asciiLowercase(string value)
{
    auto builder = appender!string;
    foreach (ch; value)
    {
        if (ch >= 'A' && ch <= 'Z')
            builder.put(cast(char) (ch + 32));
        else
            builder.put(ch);
    }
    return builder.data;
}

private bool isAsciiDigit(char ch)
{
    return ch >= '0' && ch <= '9';
}

private HttpError httpError(
    HttpErrorKind kind,
    string summary,
    HttpRequest request,
    string hint = "",
    string detail = "",
    ushort statusCode = 0,
    string[string] headers = null,
    Nullable!Duration retryAfter = Nullable!Duration.init
)
{
    HttpError error;
    error.kind = kind;
    error.method = httpMethodName(request.method);
    error.url = request.url;
    error.statusCode = statusCode;
    error.responseBody = detail;
    error.headers = headers.dup;
    error.retryAfter = retryAfter;
    error.hint = hint;
    error.message = formatError("http", summary, detail.length == 0 ? error.method ~ " " ~ error.url : detail, hint);
    return error;
}

private string joinUrl(string baseUrl, string path)
{
    auto left = baseUrl;
    auto right = path;

    if (left.length != 0 && left[$ - 1] == '/')
        left = left[0 .. $ - 1];
    if (right.length != 0 && right[0] != '/')
        right = "/" ~ right;

    return left ~ right;
}

private string normalizeAuthorization(string token)
{
    auto trimmed = token.strip;
    if (trimmed.length >= 4 && trimmed[0 .. 4] == "Bot ")
        return trimmed;
    return "Bot " ~ trimmed;
}

private bool headerExists(string[string] headers, string name)
{
    auto normalized = normalizeHeaderName(name);
    foreach (key, _; headers)
    {
        if (normalizeHeaderName(key) == normalized)
            return true;
    }
    return false;
}

private string normalizeHeaderName(string value)
{
    auto builder = appender!string;
    foreach (ch; value)
    {
        if (ch >= 'A' && ch <= 'Z')
            builder.put(cast(char) (ch + 32));
        else
            builder.put(ch);
    }
    return builder.data;
}

private string httpMethodName(HttpMethod method)
{
    final switch (method)
    {
        case HttpMethod.Get:
            return "GET";
        case HttpMethod.Post:
            return "POST";
        case HttpMethod.Put:
            return "PUT";
        case HttpMethod.Patch:
            return "PATCH";
        case HttpMethod.Delete:
            return "DELETE";
    }
}

private bool isRetryableFailure(HttpErrorKind kind)
{
    return kind == HttpErrorKind.Server ||
        kind == HttpErrorKind.Timeout ||
        kind == HttpErrorKind.Transport;
}

private Duration nextRetryDelay(Duration delay, Duration maxDelay)
{
    if (delay <= Duration.zero)
        return delay;

    auto doubled = delay + delay;
    if (maxDelay <= Duration.zero || doubled <= maxDelay)
        return doubled;
    return maxDelay;
}

private void sleepFor(Duration amount)
{
    if (amount > Duration.zero)
        Thread.sleep(amount);
}

private Nullable!string findHeaderValue(string[string] headers, string name)
{
    auto normalized = normalizeHeaderName(name);
    foreach (key, value; headers)
    {
        if (normalizeHeaderName(key) == normalized)
            return Nullable!string.of(value.strip);
    }
    return Nullable!string.init;
}

private Nullable!Duration parseRetryAfter(string[string] headers, string body)
{
    auto headerValue = findHeaderValue(headers, "Retry-After");
    if (!headerValue.isNull)
    {
        auto parsed = parseSecondsSafe(headerValue.get);
        if (!parsed.isNull)
            return parsed;
    }

    if (body.length == 0)
        return Nullable!Duration.init;

    try
    {
        auto json = parseJSON(body);
        auto retryAfter = json.object.get("retry_after", JSONValue.init);
        if (retryAfter.type == JSONType.float_)
            return parseSecondsSafe(retryAfter.floating.to!string);
        if (retryAfter.type == JSONType.integer)
            return parseSecondsSafe(retryAfter.integer.to!string);
        if (retryAfter.type == JSONType.uinteger)
            return parseSecondsSafe(retryAfter.uinteger.to!string);
        if (retryAfter.type == JSONType.string)
            return parseSecondsSafe(retryAfter.str);
    }
    catch (Exception)
    {
        return Nullable!Duration.init;
    }

    return Nullable!Duration.init;
}

private Nullable!Duration parseSecondsSafe(string value)
{
    auto trimmed = value.strip;
    if (trimmed.length == 0)
        return Nullable!Duration.init;

    try
    {
        bool sawDecimal;
        size_t decimalIndex;
        foreach (index, ch; trimmed)
        {
            if (ch == '.')
            {
                if (sawDecimal)
                    return Nullable!Duration.init;
                sawDecimal = true;
                decimalIndex = index;
            }
            else if (!(ch >= '0' && ch <= '9'))
            {
                return Nullable!Duration.init;
            }
        }

        string wholePart = trimmed;
        string fractionalPart;

        if (sawDecimal)
        {
            wholePart = trimmed[0 .. decimalIndex];
            fractionalPart = trimmed[decimalIndex + 1 .. $];
        }

        if (wholePart.length == 0)
            wholePart = "0";

        auto seconds = wholePart.to!long;
        auto parsed = dur!"seconds"(seconds);

        if (fractionalPart.length != 0)
        {
            if (fractionalPart.length > 3)
                fractionalPart = fractionalPart[0 .. 3];
            while (fractionalPart.length < 3)
                fractionalPart ~= "0";
            parsed += dur!"msecs"(fractionalPart.to!long);
        }

        if (parsed <= Duration.zero)
            return Nullable!Duration.init;

        return Nullable!Duration.of(parsed);
    }
    catch (Exception)
    {
        return Nullable!Duration.init;
    }
}

unittest
{
    HttpClientConfig config;
    assert(config.userAgent == DdiscordUserAgent);
}

unittest
{
    HttpClientConfig config;
    config.token = "token";
    HttpRequest captured;
    HttpTransport transport = (HttpRequest request) {
        captured = request;
        HttpResponse response;
        response.statusCode = 200;
        response.body = cast(ubyte[]) `{"ok":true}`.dup;
        return Result!(HttpResponse, HttpError).ok(response);
    };
    config.transport = Nullable!HttpTransport.of(transport);

    auto client = new HttpClient(config);
    HttpRequest request;
    request.url = "/users/@me";

    auto response = client.send(request).expect("request should succeed");
    assert(response.statusCode == 200);
    assert(response.json.expect("json").object["ok"].type != JSONType.null_);
    assert(captured.headers.get("User-Agent", "") == DdiscordUserAgent);
}

unittest
{
    HttpClientConfig config;
    config.token = "token";
    HttpTransport transport = (HttpRequest request) {
        HttpResponse response;
        response.statusCode = 401;
        response.body = cast(ubyte[]) `{"message":"401: Unauthorized"}`.dup;
        return Result!(HttpResponse, HttpError).err(HttpError(
            kind: HttpErrorKind.Authentication,
            message: "unauthorized",
            method: "GET",
            url: request.url
        ));
    };
    config.transport = Nullable!HttpTransport.of(transport);

    auto client = new HttpClient(config);
    HttpRequest request;
    request.url = "https://discord.com/api/v10/users/@me";

    auto result = client.send(request);
    assert(result.isErr);
}

unittest
{
    string[string] headers;
    headers["Retry-After"] = "1.5";
    auto retryAfter = parseRetryAfter(headers, "");
    assert(!retryAfter.isNull);
    assert(retryAfter.get == dur!"msecs"(1_500));
}

unittest
{
    auto retryAfter = parseRetryAfter(null, `{"retry_after":0.25}`);
    assert(!retryAfter.isNull);
    assert(retryAfter.get == dur!"msecs"(250));
}

unittest
{
    uint attempts;
    HttpTransport transport = (HttpRequest request) {
        attempts++;
        if (attempts < 3)
        {
            HttpError error;
            error.kind = HttpErrorKind.RateLimited;
            error.message = "rate limited";
            error.method = "GET";
            error.url = request.url;
            error.retryAfter = Nullable!Duration.of(dur!"msecs"(1));
            return Result!(HttpResponse, HttpError).err(error);
        }

        HttpResponse response;
        response.statusCode = 200;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    HttpClientConfig config;
    config.token = "token";
    config.maxRateLimitRetries = 3;
    config.retryBaseDelay = dur!"msecs"(1);
    config.transport = Nullable!HttpTransport.of(transport);

    auto client = new HttpClient(config);
    HttpRequest request;
    request.url = "/users/@me";

    auto result = client.send(request);
    assert(result.isOk);
    assert(attempts == 3);
}

unittest
{
    auto parsed = parseStatusCodeFromExceptionMessage("request failed with status code 422");
    assert(!parsed.isNull);
    assert(parsed.get == 422);
}

unittest
{
    HttpRequest request;
    request.method = HttpMethod.Post;
    request.url = "/interactions/1/token/callback";

    auto exception = new RequestException(
        `request failed with status code 422: {"message":"Invalid Form Body","code":50035}`
    );
    auto error = requestExceptionError(request, exception);
    assert(error.kind == HttpErrorKind.UnexpectedStatus);
    assert(error.statusCode == 422);
    assert(error.responseBody.canFind(`"Invalid Form Body"`));
}

unittest
{
    HttpRequest request;
    request.method = HttpMethod.Get;
    request.url = "/users/@me";

    auto exception = new RequestException("");
    auto error = requestExceptionError(request, exception);
    assert(error.kind == HttpErrorKind.Transport);
    assert(error.statusCode == 0);
    assert(error.responseBody.canFind("without additional message detail"));
}

unittest
{
    uint attempts;
    HttpTransport transport = (HttpRequest request) {
        attempts++;
        if (attempts < 3)
        {
            HttpError error;
            error.kind = HttpErrorKind.Server;
            error.message = "server error";
            error.method = "GET";
            error.url = request.url;
            return Result!(HttpResponse, HttpError).err(error);
        }

        HttpResponse response;
        response.statusCode = 200;
        return Result!(HttpResponse, HttpError).ok(response);
    };

    HttpClientConfig config;
    config.token = "token";
    config.maxServerErrorRetries = 3;
    config.retryBaseDelay = dur!"msecs"(1);
    config.maxRetryDelay = dur!"msecs"(1);
    config.transport = Nullable!HttpTransport.of(transport);

    auto client = new HttpClient(config);
    HttpRequest request;
    request.url = "/users/@me";

    auto result = client.send(request);
    assert(result.isOk);
    assert(attempts == 3);
}
