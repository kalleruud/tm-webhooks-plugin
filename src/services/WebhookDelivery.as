class WebhookDelivery
{
    array<PendingWebhook@> queue;
    bool stopping;

    void Enqueue(const string &in eventId, const string &in eventType, uint eventSequence, const string &in payload)
    {
        queue.InsertLast(PendingWebhook(eventId, eventType, eventSequence, payload));
    }

    void Run()
    {
        while (!stopping) {
            Poll();
            sleep(50);
        }
    }

    void Poll()
    {
        uint64 now = Time::Now;
        uint inFlight = 0;
        // Finish every active request independently, including while capture is paused.
        for (int i = int(queue.Length) - 1; i >= 0; i--) {
            PendingWebhook@ pending = queue[i];
            if (pending.request is null) continue;
            bool timedOut = !pending.request.Finished() && now - pending.startedAt >= 10000;
            if (!pending.request.Finished() && !timedOut) {
                inFlight++;
                continue;
            }
            if (timedOut) pending.request.Cancel();
            int status = timedOut ? 0 : pending.request.ResponseCode();
            if (!timedOut && status >= 200 && status < 300) {
                queue.RemoveAt(i);
                continue;
            }
            string response = timedOut ? "request timed out" : pending.request.String();
            LogResponseWarning(pending.eventId, pending.attempts, status, response);
            pending.nextAttemptAt = now + RetryDelayMs(pending.request, pending.attempts);
            @pending.request = null;
        }
        if (!CaptureEnabled()) return;
        // Backoff belongs to an event, never to the whole queue. Limit concurrency
        // so an unavailable receiver cannot create an unbounded number of requests.
        for (uint i = 0; i < queue.Length && inFlight < 4; i++) {
            PendingWebhook@ pending = queue[i];
            if (pending.request !is null || now < pending.nextAttemptAt) continue;
            @pending.request = CreateRequest(pending.eventId, pending.eventType, pending.eventSequence, pending.payload);
            if (pending.attempts < 4294967295) pending.attempts++;
            pending.startedAt = now;
            pending.request.Start();
            inFlight++;
        }
    }

    Net::HttpRequest@ CreateRequest(
        const string &in eventId,
        const string &in eventType,
        uint eventSequence,
        const string &in payload
    )
    {
        Net::HttpRequest@ request = Net::HttpRequest();
        request.Url = Setting_EndpointUrl;
        request.Method = Net::HttpMethod::Post;
        request.Headers["Content-Type"] = "application/json; charset=utf-8";
        request.Headers["event_type"] = eventType;
        request.Headers["event-type"] = eventType;
        request.Headers["event-id"] = eventId;
        request.Headers["event-sequence"] = tostring(eventSequence);
        if (Setting_AuthenticationToken.Length > 0) {
            request.Headers["Authorization"] = "Bearer " + Setting_AuthenticationToken;
        }
        request.Body = payload;
        return request;
    }

    uint64 RetryDelayMs(Net::HttpRequest@ request, uint retry)
    {
        if (!request.Finished()) return uint64(Math::Min(retry, uint(12))) * 5000;
        string retryAfter = request.ResponseHeader("Retry-After");
        if (retryAfter.Length > 0) {
            int seconds = Text::ParseInt(retryAfter);
            if (seconds > 0) return uint64(seconds) * 1000;
            int64 retryAt = Time::ParseFormatString("%a, %d %b %Y %H:%M:%S GMT", retryAfter);
            if (retryAt > Time::Stamp) return uint64(retryAt - Time::Stamp) * 1000;
        }
        return uint64(Math::Min(retry, uint(12))) * 5000;
    }

    void LogResponseWarning(const string &in id, uint attempt, int status, const string &in body)
    {
        string excerpt = body.SubStr(0, Math::Min(256, body.Length));
        warn("[http] event=" + id + " attempt=" + attempt +
            " status=" + status + " response=" + excerpt);
    }

}
