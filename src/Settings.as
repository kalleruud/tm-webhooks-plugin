[Setting name="Endpoint URL" description="Webhook destination. Capture is disabled while empty." category="Webhook"]
string Setting_EndpointUrl = "";

[Setting name="Authentication token" description="Optional bearer token. The value is never logged." category="Webhook" password]
string Setting_AuthenticationToken = "";

[Setting name="Maximum retry count" description="Retries after the initial request." category="Webhook" min=0 max=10]
uint Setting_MaximumRetryCount = 3;
