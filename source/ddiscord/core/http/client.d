/**
 * ddiscord — real HTTP client wrapper for Discord REST.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.core.http.client;

import ddiscord.util.errors : formatError;
import ddiscord.util.limits : DiscordApiBase;
import ddiscord.util.optional : Nullable;
import ddiscord.util.result : Result;
import requests.base : RequestException, Response;
import requests.request : Request;
import requests.streams : ConnectError, TimeoutException;
import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.datetime : Duration;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

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
}

/// A transport hook used for testing.
alias HttpTransport = Result!(HttpResponse, HttpError) delegate(HttpRequest request);

/// Runtime HTTP configuration.
struct HttpClientConfig
{
    string baseUrl = DiscordApiBase;
    string token;
    string userAgent = "DiscordBot (https://github.com/yourorg/ddiscord, 0.1.0)";
    Duration timeout;
    string[string] defaultHeaders;
    Nullable!HttpTransport transport;
}

/// Blocking HTTP client with Discord-specific defaults.
final class HttpClient
{
    private HttpClientConfig _config;

    this(HttpClientConfig config = HttpClientConfig.init)
    {
        _config = config;
    }

    /// Executes a request and returns either a response or a structured error.
    Result!(HttpResponse, HttpError) send(HttpRequest request)
    {
        auto prepared = prepare(request);
        if (prepared.isErr)
            return Result!(HttpResponse, HttpError).err(prepared.error);

        if (!_config.transport.isNull)
        {
            auto transport = _config.transport.get;
            return transport(prepared.value);
        }

        return execute(prepared.value);
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
        Request rq;

        if (_config.timeout != Duration.init)
            rq.timeout = _config.timeout;

        rq.addHeaders(request.headers);

        try
        {
            Response response;

            final switch (request.method)
            {
                case HttpMethod.Get:
                    response = rq.get(request.url);
                    break;
                case HttpMethod.Post:
                    response = rq.exec!"POST"(request.url, request.body, request.contentType);
                    break;
                case HttpMethod.Put:
                    response = rq.exec!"PUT"(request.url, request.body, request.contentType);
                    break;
                case HttpMethod.Patch:
                    response = rq.exec!"PATCH"(request.url, request.body, request.contentType);
                    break;
                case HttpMethod.Delete:
                    if (request.body.length == 0)
                        response = rq.exec!"DELETE"(request.url);
                    else
                        response = rq.exec!"DELETE"(request.url, request.body, request.contentType);
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
            return Result!(HttpResponse, HttpError).err(httpError(
                HttpErrorKind.Transport,
                "The HTTP client failed while talking to Discord.",
                request,
                "Inspect the nested error detail for transport-specific information.",
                e.msg
            ));
        }
        catch (Exception e)
        {
            return Result!(HttpResponse, HttpError).err(httpError(
                HttpErrorKind.Transport,
                "An unexpected HTTP client failure occurred.",
                request,
                "This usually indicates a local networking issue or malformed request configuration.",
                e.msg
            ));
        }
    }

    private HttpError statusError(HttpRequest request, HttpResponse response)
    {
        auto body = response.text;

        if (response.statusCode == 401)
        {
            return httpError(
                HttpErrorKind.Authentication,
                "Discord rejected the request because the bot token was invalid or missing required authentication.",
                request,
                "Ensure the token is correct and includes the `Bot ` prefix only once.",
                body,
                response.statusCode,
                response.headers
            );
        }

        if (response.statusCode == 403)
        {
            return httpError(
                HttpErrorKind.Forbidden,
                "Discord refused the request because the bot lacks permission for this action.",
                request,
                "Verify the bot's guild permissions, channel overwrites, and application scopes.",
                body,
                response.statusCode,
                response.headers
            );
        }

        if (response.statusCode == 404)
        {
            return httpError(
                HttpErrorKind.NotFound,
                "Discord could not find the requested resource.",
                request,
                "Double-check IDs such as channel, message, interaction, or application identifiers.",
                body,
                response.statusCode,
                response.headers
            );
        }

        if (response.statusCode == 429)
        {
            return httpError(
                HttpErrorKind.RateLimited,
                "Discord rate limited the request.",
                request,
                "Respect `Retry-After` and `X-RateLimit-*` headers before retrying.",
                body,
                response.statusCode,
                response.headers
            );
        }

        if (response.statusCode >= 500)
        {
            return httpError(
                HttpErrorKind.Server,
                "Discord returned a server-side error.",
                request,
                "Retry with backoff. If the problem persists, Discord may be degraded.",
                body,
                response.statusCode,
                response.headers
            );
        }

        return httpError(
            HttpErrorKind.UnexpectedStatus,
            "Discord returned an unexpected HTTP status code.",
            request,
            "Inspect the response body and headers for Discord's error details.",
            body,
            response.statusCode,
            response.headers
        );
    }
}

private HttpError httpError(
    HttpErrorKind kind,
    string summary,
    HttpRequest request,
    string hint = "",
    string detail = "",
    ushort statusCode = 0,
    string[string] headers = null
)
{
    HttpError error;
    error.kind = kind;
    error.method = httpMethodName(request.method);
    error.url = request.url;
    error.statusCode = statusCode;
    error.responseBody = detail;
    error.headers = headers.dup;
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

unittest
{
    HttpClientConfig config;
    config.token = "token";
    HttpTransport transport = (HttpRequest request) {
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
