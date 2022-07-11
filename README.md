Safer S3 signed URLs

## The problem

A webserver controls access to content. Maybe that content is photos, maybe
it's proprietary-licensed software, maybe it's bank statements. Let's stick
with photos for now, like the photo-sharing products from Google or Facebook.

For any given photo, there's a list of people who should have access to it;
this list changes over time.  The webserver is good at figuring out which
photos should be accessible to which people. It's less good at storing and
serving the photos: it offloads that task to a blobstore, like Amazon S3.

Amazon S3 isn't very good at figuring out which users should have access to
which content. It essentially has two modes: public and private. In public
mode, anyone who knows a photo's location in the blobstore can download it. In
private mode, IAM credentials are needed. We can't grant users IAM credentials:
AWS IAM was built for hundreds or low-thousands of infrequently changing users,
which is too few for our service.

One solution is for the webserver to sign URLs and pass them to users.
Provision the webserver with credentials to access any photo. When it decides
to show a photo to a given user, it signs a request (a URL) for the photo to
S3, but it sends the request to the user, rather than to S3. The user receives
the URL, sends it to S3, and receives a photo.

The problem with this approach is that URLs are generally not considered
secret. Browser extensions scrape them. Search engines index them. Chat clients
preview them. With signed URLs, it is very easy for a user to leak access to
others, usually without knowing it. The [AWS docs][aws] say:

[aws]: https://docs.aws.amazon.com/general/latest/gr/sigv4-add-signature-to-request.html

    ⚠️ Important

    If you make a request in which all parameters are included in the query string,
    the resulting URL represents an AWS action that is already authenticated.
    Therefore, treat the resulting URL with as much caution as you would treat your
    actual credentials. We recommend you specify a short expiration time for the
    request with the X-Amz-Expires parameter.

I think this overstates the problem: a signed URL is good for retrieving
exactly one thing, whereas my credentials can retrieve anything. There's a
difference. But the message remains the same: a signed URL is a transferrable
[capability][capability] to access data, and beause the capability is wrapped
up in a URL it can be very easily and casually transferred.

[capability]: https://en.wikipedia.org/wiki/Capability-based_security

What we'd like is some way to make it a bit more difficult to casually transfer
the URL. We're not trying to prevent the data from escaping entirely: the goal
isn't a DRM solution. Instead, we just want it to be mildly difficult, in a
"locks keep honest people out" sense.

## Solution

Split the capability into two parts:
1. the signed URL
2. a cookie, known by the user's browser but not typically displayed

Amazon S3 can be instructed to look for the presence of a particular header
when authorizing a request, through the SignedHeaders feature of AWS
SignatureV4. Unfortunately for us, we cannot set cookies on S3 domain names.
But we can set cookies on our own domain names, and use a CDN to forward
requests to S3. In this example I chose Cloudfront.

I think in principle it would be possible to have S3 authenticate directly on
the user's Cookie header. In practice, I found that Cloudfront disallows
sending the cookie header, at least to S3 origins. We could copy the cookie
directly into a header and send it to S3, but this has a few minor drawbacks:
1. S3 outputs detailed error messages when an incorrect signature is produced.
   These include the values passed to it, which would reveal the user's cookie
on their screen.
2. If the cookie allows the user to access other parts of your service, then
   this makes S3 part of your threat model. If S3 started logging its inbound
headers, you'd be giving your cookies directly to S3.  if you get a signature
wrong

I ended up sending the header to S3 as HMAC(pepper, cookie + path). The
[pepper][pepper] is a fixed secret known to my webapp and Cloudfront. It
ensures that users cannot circumvent my CDN to produce a "fully signed" URL
from the partial ones I am giving them. This transformation occurs within a
Cloudfront function.

[pepper]: https://en.wikipedia.org/wiki/Pepper_(cryptography)

The full flow is:
1. user visits my webapp and requests a link to a given resource
2. webapp checks that the user should have access
3. webapp takes user's cookie, a fixed secret pepper, and the requested path
   and computes secret=HMAC(pepper, cookie + path)
4. webapp signs a URL to access the resource in S3, with an additional signed
   header containing the calculated secret.
5. webapp replaces the S3 host in the URL with the hostname of my Cloudfront
   distribution.
5. webapp sends the signed URL to the user, but omits the secret
6. user's browser requests the URL it received, and sends its cookie.
7. a cloudfront function recomputes the secret that the webapp computed in step
   3 and adds it to the request.
8. cloudfront makes the request and returns the result to the user.

This repository contains Terraform code sufficient to demonstrate the solution.
For my "webapp", I made a Lambda@Edge function in Python that grants access to
a single fixed resource in S3 to anyone who requests it.
