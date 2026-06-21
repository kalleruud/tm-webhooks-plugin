class WebhookDelivery
{
    array<PendingWebhook@> queue;
    bool stopping;

    void Enqueue(const string &in eventId, const string &in eventType, uint eventSequence, const string &in payload)
    {
        if (queue.Length >= MAX_QUEUE_SIZE) {
            error("[drop] event=" + eventId + " reason=queue-full");
            return;
        }
        queue.InsertLast(PendingWebhook(eventId, eventType, eventSequence, payload));
    }

    void Run()
    {
        while (!stopping) {
            if (queue.IsEmpty() || !CaptureEnabled()) {
                sleep(100);
                continue;
            }
            DeliverFirst();
        }
    }

    void DeliverFirst()
    {
        PendingWebhook@ pending = queue[0];
        uint retries = 0;
        while (true) {
            string authToken = AcquireAuthToken();
            if (authToken.Length == 0) {
                LogResponseWarning(pending.eventId, retries + 1, 0, "Openplanet authentication failed");
                if (retries >= Setting_MaximumRetryCount) {
                    LogDropped(pending.eventId, retries + 1, 0, "Openplanet authentication failed");
                    break;
                }
                retries++;
                sleep(RetryDelayMs(retries));
                continue;
            }
            Net::HttpRequest@ request = CreateRequest(
                pending.eventId,
                pending.eventType,
                pending.eventSequence,
                pending.payload,
                authToken
            );
            request.Start();
            uint startedAt = Time::Now;
            while (!request.Finished() && Time::Now - startedAt < 10000) yield();
            bool timedOut = !request.Finished();
            if (timedOut) request.Cancel();
            int status = timedOut ? 0 : request.ResponseCode();
            if (!timedOut && status >= 200 && status < 300) break;
            string response = timedOut ? "request timed out" : request.String();
            LogResponseWarning(pending.eventId, retries + 1, status, response);
            if (!IsRetryable(status) || retries >= Setting_MaximumRetryCount) {
                LogDropped(pending.eventId, retries + 1, status, response);
                break;
            }
            retries++;
            sleep(RetryDelayMs(request, retries));
        }
        queue.RemoveAt(0);
    }

    string AcquireAuthToken()
    {
        auto tokenTask = Auth::GetToken();
        while (!tokenTask.Finished()) yield();
        return tokenTask.Token();
    }

    Net::HttpRequest@ CreateRequest(
        const string &in eventId,
        const string &in eventType,
        uint eventSequence,
        const string &in payload,
        const string &in authToken
    )
    {
        Net::HttpRequest@ request = Net::HttpRequest();
        request.Url = Setting_EndpointUrl;
        request.Method = Net::HttpMethod::Post;
        request.Headers["Content-Type"] = "application/json; charset=utf-8";
        request.Headers["event_type"] = eventType;
        request.Headers["event-id"] = eventId;
        request.Headers["event-sequence"] = tostring(eventSequence);
        request.Headers["Authorization"] = "Bearer " + authToken;
        request.Body = payload;
        return request;
    }

    bool IsRetryable(int status)
    {
        return status == 0 || status == 408 || status == 429 || status >= 500;
    }

    uint RetryDelayMs(Net::HttpRequest@ request, uint retry)
    {
        string retryAfter = request.ResponseHeader("Retry-After");
        if (retryAfter.Length > 0) {
            int seconds = Text::ParseInt(retryAfter);
            if (seconds > 0) return uint(seconds) * 1000;
            int64 retryAt = Time::ParseFormatString("%a, %d %b %Y %H:%M:%S GMT", retryAfter);
            if (retryAt > Time::Stamp) return uint(retryAt - Time::Stamp) * 1000;
        }
        return RetryDelayMs(retry);
    }

    uint RetryDelayMs(uint retry) { return retry * 5000; }

    void LogResponseWarning(const string &in id, uint attempt, int status, const string &in body)
    {
        string excerpt = body.SubStr(0, Math::Min(256, body.Length));
        warn("[http] event=" + id + " attempt=" + attempt +
            " status=" + status + " response=" + excerpt);
    }

    void LogDropped(const string &in id, uint attempts, int status, const string &in body)
    {
        string excerpt = body.SubStr(0, Math::Min(256, body.Length));
        error("[drop] event=" + id + " attempts=" + attempts +
            " status=" + status + " response=" + excerpt);
    }
}
