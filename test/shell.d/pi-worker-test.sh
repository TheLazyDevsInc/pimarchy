#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The download Worker (pi/worker/worker.mjs) against a stand-in for GitHub: a
# releases feed, each release's pimarchy.json as pi/release-manifest writes it,
# and parts served with byte ranges, as GitHub's release downloads serve them.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Two releases' images, split as the release workflow splits them, and their
# manifests from pi/release-manifest itself.
for release in rel1 rel2; do
  mkdir -p "$tmp/$release"
  head -c 3000 /dev/urandom | xz -T1 >"$tmp/$release/$release.img.xz"
  split -b 400 -d -a 1 "$tmp/$release/$release.img.xz" "$tmp/$release/$release.img.xz.part"
  "$ROOT/pi/release-manifest" "$tmp/$release/$release.img.xz" "$tmp/$release/$release.img.xz".part? >"$tmp/$release/pimarchy.json" ||
    fail "pi/release-manifest writes $release's manifest"
done
pass "pi/release-manifest writes a manifest for an image and its parts"

status=0
output=$("$ROOT/pi/release-manifest" "$tmp/rel1/rel1.img.xz" "$tmp/rel1/rel1.img.xz.part0" 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"the parts hold 400 bytes"* ]] || fail "pi/release-manifest refuses parts that aren't the image" "$output"
pass "pi/release-manifest refuses parts that don't make up the image"

TMP=$tmp run_node_test <<'JS'
const fs = require('fs')
const crypto = require('crypto')
const { pathToFileURL } = require('url')
const tmp = process.env.TMP
const repo = 'owner/pimarchy'
const base = `https://github.com/${repo}`

const files = {}
for (const release of ['rel1', 'rel2']) {
  for (const name of fs.readdirSync(path.join(tmp, release))) {
    files[`${base}/releases/download/${release}/${name}`] = fs.readFileSync(path.join(tmp, release, name))
  }
}
// The newest release has no manifest yet, and one has a manifest whose parts
// don't add up: both are passed over.
const broken = JSON.parse(files[`${base}/releases/download/rel1/pimarchy.json`])
broken.parts[0].size += 1
files[`${base}/releases/download/broken/pimarchy.json`] = Buffer.from(JSON.stringify(broken))
files[`${base}/releases.atom`] = Buffer.from(`<?xml version="1.0"?><feed>
  <link type="text/html" rel="alternate" href="${base}/releases"/>
  <entry><link rel="alternate" type="text/html" href="${base}/releases/tag/building"/></entry>
  <entry><link rel="alternate" type="text/html" href="${base}/releases/tag/broken"/></entry>
  <entry><link rel="alternate" type="text/html" href="${base}/releases/tag/rel2"/></entry>
  <entry><link rel="alternate" type="text/html" href="${base}/releases/tag/rel1"/></entry>
</feed>`)

let requests = []
let ignoreRanges = false
const failing = new Set()
globalThis.fetch = async (url, init = {}) => {
  const range = (init.headers || {}).Range
  requests.push(range ? `${url} ${range}` : url)
  if (failing.has(url)) return new Response('Unicorn', { status: 500 })
  const body = files[url]
  if (!body) return new Response('Not Found', { status: 404 })
  const match = range && !ignoreRanges && /^bytes=(\d+)-(\d+)$/.exec(range)
  if (!match) return new Response(body, { status: 200, headers: { 'Content-Length': String(body.length) } })
  const [from, to] = [Number(match[1]), Number(match[2])]
  return new Response(body.subarray(from, to + 1), {
    status: 206,
    headers: { 'Content-Length': String(to - from + 1), 'Content-Range': `bytes ${from}-${to}/${body.length}` },
  })
}

const image = (release) => files[`${base}/releases/download/${release}/${release}.img.xz`]
const parts = (release) => Object.keys(files).filter((url) => url.includes(`/${release}/${release}.img.xz.part`)).sort()

;(async () => {
  const worker = await import(pathToFileURL(path.join(root, 'pi/worker/worker.mjs')))
  const env = { REPO: repo }
  const get = (path, headers = {}, method = 'GET') =>
    worker.default.fetch(new Request(`https://pimarchy.example.workers.dev${path}`, { method, headers }), env, {})
  const bytes = async (response) => Buffer.from(await response.arrayBuffer())

  // The latest image is a redirect to the newest release's own, so a client
  // reads its size and its bytes from the one release.
  let response = await get('/latest.img.xz')
  assert(response.status === 302 && response.headers.get('Location') === 'https://pimarchy.example.workers.dev/rel2.img.xz' &&
    response.headers.get('Cache-Control') === 'no-store',
    'the latest image redirects, uncached, to the newest release with a manifest',
    `status ${response.status}, ${response.headers.get('Location')}`)
  assert(!requests.some((r) => r.includes('.part')), 'the redirect reads no part')
  response = await get('/rel2.img.xz')
  let body = await bytes(response)
  assert(response.status === 200 && body.equals(image('rel2')),
    'a release is served whole, its parts joined in order', `status ${response.status}, ${body.length} bytes`)
  assertEqual(response.headers.get('Content-Length'), String(image('rel2').length), 'the whole image has its length')
  assertEqual(response.headers.get('Accept-Ranges'), 'bytes', 'byte ranges are offered')
  assertEqual(response.headers.get('Content-Disposition'), 'attachment; filename="rel2.img.xz"', 'the download is named after the image')
  assert(!requests.some((r) => r.includes('/building/') && !r.endsWith('pimarchy.json')) &&
    !requests.some((r) => r.includes('/broken/') && !r.endsWith('pimarchy.json')),
    'releases without a sound manifest are passed over', requests.join('\n'))

  // A range across the boundary of the first two parts reads only them.
  requests = []
  response = await get('/rel2.img.xz', { Range: 'bytes=350-450' })
  body = await bytes(response)
  assert(response.status === 206 && body.equals(image('rel2').subarray(350, 451)),
    'a range across two parts is served from them', `status ${response.status}`)
  assertEqual(response.headers.get('Content-Range'), `bytes 350-450/${image('rel2').length}`, 'the range says where it lies')
  const [part0, part1] = parts('rel2')
  assertDeepEqual(requests.filter((r) => r.includes('.part')), [`${part0} bytes=350-399`, `${part1} bytes=0-50`],
    'only the parts a range covers are read, and only those bytes')

  // A suffix range, as a reader of the xz index at the end of the image asks.
  requests = []
  const size = image('rel2').length
  response = await get('/rel2.img.xz', { Range: 'bytes=-100' })
  body = await bytes(response)
  assert(response.status === 206 && body.equals(image('rel2').subarray(size - 100)), 'the last bytes are served for a suffix range')
  assertEqual(requests.filter((r) => r.includes('.part')).length, size % 400 >= 100 ? 1 : 2, 'a suffix range reads the last parts only')

  response = await get('/rel2.img.xz', { Range: `bytes=${size}-` })
  assert(response.status === 416 && response.headers.get('Content-Range') === `bytes */${size}`,
    'a range past the end is refused', `status ${response.status}`)
  response = await get('/rel2.img.xz', { Range: 'bytes=0-10', 'If-Range': '"stale"' })
  assert(response.status === 200 && (await bytes(response)).equals(image('rel2')), 'a range for another version of the image gets the whole image')

  requests = []
  response = await get('/rel2.img.xz', {}, 'HEAD')
  assert(response.status === 200 && response.headers.get('Content-Length') === String(size) && !requests.some((r) => r.includes('.part')),
    'HEAD answers with the length and reads no part')
  response = await get('/rel2.img.xz', { Range: 'bytes=0-10' }, 'HEAD')
  assert(response.status === 200 && response.headers.get('Content-Length') === String(size) && !response.headers.get('Content-Range'),
    'HEAD describes the whole image, a range or not', `status ${response.status}`)

  const sha256 = crypto.createHash('sha256').update(image('rel2')).digest('hex')
  response = await get('/latest.img.xz.sha256')
  assertEqual(response.headers.get('Location'), 'https://pimarchy.example.workers.dev/rel2.img.xz.sha256', 'the latest checksum redirects to the release\'s')
  response = await get('/rel2.img.xz.sha256')
  assertEqual(await response.text(), `${sha256}  rel2.img.xz\n`, 'the checksum is served as sha256sum -c reads it')
  response = await get('/rel2.json')
  const manifest = await response.json()
  assert(manifest.tag === 'rel2' && manifest.image === 'rel2.img.xz' && manifest.parts.length === parts('rel2').length,
    'the manifest is served with its tag')

  response = await get('/rel1.img.xz')
  assert(response.status === 200 && (await bytes(response)).equals(image('rel1')), 'a release is served by its tag')
  response = await get('/building.img.xz')
  assertEqual(response.status, 404, 'a release without a manifest is not found')

  // GitHub failing to send the newest release's manifest is GitHub failing, not
  // the release having none: the newest isn't passed over for an older one.
  failing.add(`${base}/releases/download/rel2/pimarchy.json`)
  response = await get('/latest.img.xz')
  assertEqual(response.status, 502, 'GitHub failing reads as that, not as an older release being the newest')
  failing.clear()

  // A part sent other than as asked ends the download with an error.
  ignoreRanges = true
  response = await get('/rel2.img.xz', { Range: 'bytes=350-450' })
  let failed = false
  try {
    await bytes(response)
  } catch {
    failed = true
  }
  assert(failed, 'a part GitHub sends whole when a range was asked for fails the download instead of corrupting it')
  ignoreRanges = false

  assertEqual((await get('/other.txt')).status, 404, 'other paths are not found')
  assertEqual((await get('/..%2F..%2Fsomething.img.xz')).status, 404, 'a name with dots first reaches nothing')
  assertEqual((await get('/latest.img.xz', {}, 'POST')).status, 405, 'only GET and HEAD are answered')
})().catch((error) => fail('the Worker test ran to its end', error.stack))
JS
