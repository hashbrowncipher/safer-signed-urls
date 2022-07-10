Combines cookie-based authentication with S3-signed URLs

## Abstractly

With a typical signed URL, anyone who gets the URL can retrieve the asset. This
makes signed URLs dangerous, because many pieces of software are happy to issue
HTTP GETs against any URL they see, without regard to user privacy.

The typical alternative is cookie-based authZ, but these usually require a
stateful database lookup to make the granular determination of whether a user
should have access to a given resource. For instance, many webappscheck a
user's identity (AuthN), determine whether they should be able to access a
certain resource (AuthZ), and then serve the resource. But oftentimes the last
step (serving the resource) is costly from a performance perspective, and we
would prefer to decouple the security tasks from the byte-shoveling tasks.

This solution melds both of the above techniques. With this approach, each user
is issued a cookie when they log in. Users request resources, and a webapp
decides which requests to authorize on a granular basis. When authorization is
successful, the webapp issues a signed URL to the client, which the client then
uses to retrieve the data. The signed URL cannot be used on its own: S3 only
sends the data when the request contains both the signed URL and the same
user's cookie.

## Concretely

    Client ---> Cloudfront -> S3
           |
           ---> Webapp
           

1. An S3 bucket holds private data.
2. A cloudfront distribution sits receives client traffic, with its origin
   pointing at the S3 bucket. Cloudfront does _not_ have the requisite
credentials to retrieve data from the S3 bucket on its own.
3. A "webapp" (in this case a Python script running within Lambda@Edge) issues
   cookies to its users, and signs URL pointing at Cloudfront. It does this
according to whatever authorization logic makes sense for its needs. The signed
URLs it sends to its callers are configured to require an additional header;
clients never receive this header.
4. Clients use their signed URLs, which lead them to make requests against
   Cloudfront. When a request arrives at Cloudfront, a Cloudfront Function
examines the cookie sent with the request, and performs a cryptographic
operation (HMAC) with a shared-secret known to the Cloudfront Function (and the
webapp). Cloudfront appends the computed HMAC as a header atop the user's
request and sends it upstream to the S3 bucket.
5. When the request reaches S3, AWS IAM examines the signature on the request.
   Since cloudfront added the header, AWS IAM allows the request. If the
   request had bypassed Cloudfront, AWS IAM would reject it.
