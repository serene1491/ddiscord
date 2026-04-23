/**
 * ddiscord — multipart/form-data helpers.
 *
 * Part of ddiscord, a modular Discord bot engine for D.
 * License: MIT
 */
module ddiscord.core.http.multipart;

import ddiscord.util.optional : Nullable;
import std.algorithm : canFind;
import std.array : Appender, appender;
import std.conv : to;
import std.datetime : Clock;

/// A single multipart form-data part.
struct MultipartPart
{
    string name;
    Nullable!string filename;
    string contentType;
    ubyte[] data;

    static MultipartPart text(string name, string value, string contentType = "text/plain; charset=utf-8")
    {
        MultipartPart part;
        part.name = name;
        part.contentType = contentType;
        part.data = cast(ubyte[]) value.dup;
        return part;
    }

    static MultipartPart file(
        string name,
        string filename,
        ubyte[] data,
        string contentType = "application/octet-stream"
    )
    {
        MultipartPart part;
        part.name = name;
        part.filename = Nullable!string.of(filename);
        part.contentType = contentType;
        part.data = data.dup;
        return part;
    }
}

/// Encoded multipart body plus the generated boundary and Content-Type header.
struct MultipartEncoded
{
    string boundary;
    string contentType;
    ubyte[] body;
}

/// Encodes multipart/form-data bytes for HTTP requests.
MultipartEncoded encodeMultipartFormData(MultipartPart[] parts, string boundary = "")
{
    MultipartEncoded encoded;
    encoded.boundary = boundary.length == 0 ? defaultBoundary() : boundary;
    encoded.contentType = "multipart/form-data; boundary=" ~ encoded.boundary;

    auto buffer = appender!(ubyte[])();
    foreach (part; parts)
    {
        appendText(buffer, "--" ~ encoded.boundary ~ "\r\n");

        auto disposition = "Content-Disposition: form-data; name=\"" ~ sanitizeDisposition(part.name) ~ "\"";
        if (!part.filename.isNull)
        {
            disposition ~= "; filename=\"" ~ sanitizeDisposition(part.filename.get) ~ "\"";
        }
        appendText(buffer, disposition ~ "\r\n");

        if (part.contentType.length != 0)
            appendText(buffer, "Content-Type: " ~ part.contentType ~ "\r\n");

        appendText(buffer, "\r\n");
        buffer.put(part.data);
        appendText(buffer, "\r\n");
    }

    appendText(buffer, "--" ~ encoded.boundary ~ "--\r\n");
    encoded.body = buffer.data;
    return encoded;
}

private string defaultBoundary()
{
    return "----ddiscord-" ~ Clock.currTime().stdTime.to!string;
}

private void appendText(ref Appender!(ubyte[]) buffer, string value)
{
    buffer.put(cast(const(ubyte)[]) value);
}

private string sanitizeDisposition(string value)
{
    char[] clean;
    foreach (ch; value)
    {
        if (ch == '"' || ch == '\r' || ch == '\n')
            clean ~= '_';
        else
            clean ~= ch;
    }
    return clean.idup;
}

unittest
{
    MultipartPart[] parts;
    parts ~= MultipartPart.text("payload_json", `{"content":"hello"}`, "application/json");
    parts ~= MultipartPart.file("files[0]", "hello.txt", cast(ubyte[]) "hello".dup, "text/plain");

    auto encoded = encodeMultipartFormData(parts, "test-boundary");
    auto text = cast(string) encoded.body;

    assert(encoded.contentType == "multipart/form-data; boundary=test-boundary");
    assert(text.canFind(`name="payload_json"`));
    assert(text.canFind(`Content-Type: application/json`));
    assert(text.canFind(`name="files[0]"; filename="hello.txt"`));
    assert(text.canFind("hello"));
    assert(text.canFind("--test-boundary--"));
}
