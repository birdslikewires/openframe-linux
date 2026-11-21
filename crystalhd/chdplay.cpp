// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Andrew Davison
//
// chdplay: Crystal HD video player for the OpenFrame 2.
//
// Input: libavformat on reader threads (one per input), so a slow network never holds up decoding
//        or presentation; network inputs reconnect when the server drops them.
// Video: (h264_mp4toannexb) -> BCM70015, scaled on the card to the panel width -> YUY2 ->
//        libswscale -> XRGB8888 in a KMS dumb buffer, page-flipped on vblank.
// Audio: libavcodec (software) -> libswresample (S16 stereo) -> ALSA, on its own thread; from the
//        main input or a separate one (--audio, for sources such as YouTube that keep them apart).
// Sync:  stream timestamps; audio is the master clock, late pictures are dropped, early ones wait.
//        When an input runs dry the clock pauses until enough is buffered, instead of dropping.
// FFmpeg dropped its Crystal HD decoders in 2024, so only its demuxers and audio decoders are used.
//
// Usage: sudo chdplay [options] file|URL
//   --audio URL play the sound from this input instead of the main one
//   --buffer S  seconds to buffer before starting and after running dry (default 2; doubles
//               after each stall, up to 8)
//   --scale W   ask the card to output W pixels wide (default: panel width; 0 = off)
//   --fps N     override the stream's frame rate (raw .264 files have none)
//   --bench     no audio, present every picture as soon as it is ready
//   --lead S    seconds of video the card may hold ahead of its output (default 3, 0 = no limit)
//   --noaudio   play video only
//   --timeout S give up after S seconds (default: none)
//   --maxtemp C stop if the chip's sensor passes C degrees (default 88)

#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <sys/mman.h>
#include <semaphore.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <alsa/asoundlib.h>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
}
#include "7411d.h"		/* must come first: defines C011_PIB, as in libcrystalhd_if.cpp */
#include "libcrystalhd_if.h"
#include "libcrystalhd_int_if.h"

static const char *USAGE =
	"usage: chdplay [--audio URL] [--buffer S] [--scale W|0] [--fps N] [--bench] [--noaudio]\n"
	"               [--timeout S] [--lead S] [--maxtemp C] file|URL\n";

static float chip_temp(HANDLE dev)
{
	float t = 0;
	DtsGetCoreTemperature(dev, &t);
	return t;
}

static bool verbose = false;			/* CHD_VERBOSE */
static std::atomic<bool> stop{false};		/* Ctrl-C, timeout: stop everything now */
static std::atomic<bool> quit_input{false};	/* playback is over: readers stop */
static void on_signal(int) { stop = true; }
static int interrupt_cb(void *) { return stop || quit_input; }	/* breaks blocking network reads */

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---------------- display: two dumb buffers, page flipped ---------------- */

struct Buf { uint32_t handle, pitch, fb; uint64_t size; uint8_t *map; };

struct Disp {
	int fd = -1;
	uint32_t conn = 0, crtc = 0;
	drmModeModeInfo mode;
	drmModeCrtc *saved = nullptr;
	Buf b[2] = {};
	int front = 0;
	bool flip_ok = true, pending = false;
};

static void flip_done(int, unsigned, unsigned, unsigned, void *data) { ((Disp *)data)->pending = false; }

static void wait_flip(Disp &d)
{
	drmEventContext ev;
	memset(&ev, 0, sizeof(ev));
	ev.version = 2;
	ev.page_flip_handler = flip_done;
	while (d.pending && !stop) {
		struct pollfd p = { d.fd, POLLIN, 0 };
		if (poll(&p, 1, 200) > 0) drmHandleEvent(d.fd, &ev);
		else d.pending = false;
	}
}

static bool disp_open(Disp &d)
{
	d.fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (d.fd < 0) { perror("/dev/dri/card0"); return false; }
	drmModeRes *res = drmModeGetResources(d.fd);
	if (!res) { perror("drmModeGetResources"); return false; }
	for (int i = 0; i < res->count_connectors && !d.conn; i++) {
		drmModeConnector *c = drmModeGetConnector(d.fd, res->connectors[i]);
		if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes) {
			d.conn = c->connector_id;
			d.mode = c->modes[0];
			for (int m = 0; m < c->count_modes; m++)
				if (c->modes[m].type & DRM_MODE_TYPE_PREFERRED) d.mode = c->modes[m];
			drmModeEncoder *e = c->encoder_id ? drmModeGetEncoder(d.fd, c->encoder_id) : nullptr;
			if (e && e->crtc_id) d.crtc = e->crtc_id;
			for (int k = 0; k < res->count_crtcs && !d.crtc; k++)
				if (e && (e->possible_crtcs & (1u << k))) d.crtc = res->crtcs[k];
			if (e) drmModeFreeEncoder(e);
		}
		if (c) drmModeFreeConnector(c);
	}
	drmModeFreeResources(res);
	if (!d.conn || !d.crtc) { fprintf(stderr, "no connected display\n"); return false; }

	d.saved = drmModeGetCrtc(d.fd, d.crtc);
	for (int i = 0; i < 2; i++) {
		struct drm_mode_create_dumb cr = {};
		cr.width = d.mode.hdisplay;
		cr.height = d.mode.vdisplay;
		cr.bpp = 32;
		if (drmIoctl(d.fd, DRM_IOCTL_MODE_CREATE_DUMB, &cr)) { perror("create dumb"); return false; }
		d.b[i].handle = cr.handle;
		d.b[i].pitch = cr.pitch;
		d.b[i].size = cr.size;
		if (drmModeAddFB(d.fd, cr.width, cr.height, 24, 32, cr.pitch, cr.handle, &d.b[i].fb)) {
			perror("drmModeAddFB"); return false;
		}
		struct drm_mode_map_dumb mp = {};
		mp.handle = cr.handle;
		if (drmIoctl(d.fd, DRM_IOCTL_MODE_MAP_DUMB, &mp)) { perror("map dumb"); return false; }
		d.b[i].map = (uint8_t *)mmap(0, cr.size, PROT_READ | PROT_WRITE, MAP_SHARED, d.fd, mp.offset);
		if (d.b[i].map == MAP_FAILED) { d.b[i].map = nullptr; perror("mmap"); return false; }
		memset(d.b[i].map, 0, cr.size);
	}
	if (drmModeSetCrtc(d.fd, d.crtc, d.b[0].fb, 0, 0, &d.conn, 1, &d.mode)) {
		perror("drmModeSetCrtc"); return false;
	}
	return true;
}

static void present(Disp &d, int idx)
{
	if (d.flip_ok) {
		if (drmModePageFlip(d.fd, d.crtc, d.b[idx].fb, DRM_MODE_PAGE_FLIP_EVENT, &d) == 0) {
			d.pending = true;
			d.front = idx;
			return;
		}
		printf("page flip unsupported, falling back to SetCrtc (may tear)\n");
		d.flip_ok = false;
	}
	drmModeSetCrtc(d.fd, d.crtc, d.b[idx].fb, 0, 0, &d.conn, 1, &d.mode);
	d.front = idx;
}

static void disp_close(Disp &d)
{
	if (d.fd < 0) return;
	wait_flip(d);
	if (d.saved) {	/* hand the panel back to the console */
		drmModeSetCrtc(d.fd, d.saved->crtc_id, d.saved->buffer_id, d.saved->x, d.saved->y,
			       &d.conn, 1, &d.saved->mode);
		drmModeFreeCrtc(d.saved);
	}
	for (int i = 0; i < 2; i++) {
		if (d.b[i].map) munmap(d.b[i].map, d.b[i].size);
		if (d.b[i].fb) drmModeRmFB(d.fd, d.b[i].fb);
		struct drm_mode_destroy_dumb ds = { d.b[i].handle };
		if (d.b[i].handle) drmIoctl(d.fd, DRM_IOCTL_MODE_DESTROY_DUMB, &ds);
	}
	close(d.fd);
}

/* ---------------- packet queue ---------------- */

/* Packets with their stream time in seconds (dts, else pts): the queue knows how much it holds
 * (duration) and how far its reader has got (latest). */
struct PktQueue {
	struct Item { AVPacket *p; double t; };
	std::mutex m;
	std::condition_variable cv;
	std::deque<Item> q;
	bool done = false;
	double tail = -1e9;	/* latest time pushed */
	size_t nbytes = 0;

	void push(AVPacket *p, double t) {
		{
			std::lock_guard<std::mutex> l(m);
			if (std::isnan(t)) t = tail > -1e8 ? tail : 0;	/* no timestamp: as the one before */
			q.push_back({ p, t });
			nbytes += p->size;
			tail = std::max(tail, t);
		}
		cv.notify_all();
	}
	void finish() { { std::lock_guard<std::mutex> l(m); done = true; } cv.notify_all(); }
	size_t size() { std::lock_guard<std::mutex> l(m); return q.size(); }
	size_t bytes() { std::lock_guard<std::mutex> l(m); return nbytes; }
	bool finished() { std::lock_guard<std::mutex> l(m); return done; }
	double latest() { std::lock_guard<std::mutex> l(m); return tail; }
	double duration() { std::lock_guard<std::mutex> l(m); return q.empty() ? 0 : tail - q.front().t; }
	AVPacket *take_front() {	/* with m held */
		AVPacket *p = q.front().p;
		q.pop_front();
		nbytes -= p->size;
		return p;
	}
	/* nullptr = no more packets, or (with *timed_out set) none arrived within secs */
	AVPacket *pop_wait_for(double secs, bool *timed_out) {
		std::unique_lock<std::mutex> l(m);
		*timed_out = !cv.wait_for(l, std::chrono::duration<double>(secs),
					  [&] { return !q.empty() || done || stop; });
		if (*timed_out || q.empty()) return nullptr;
		return take_front();
	}
	AVPacket *try_pop() {
		std::lock_guard<std::mutex> l(m);
		return q.empty() ? nullptr : take_front();
	}
	AVPacket *peek() { std::lock_guard<std::mutex> l(m); return q.empty() ? nullptr : q.front().p; }
	void trim_after(double t) {	/* drop queued packets later than t */
		std::lock_guard<std::mutex> l(m);
		while (!q.empty() && q.back().t > t) {
			AVPacket *p = q.back().p;
			q.pop_back();
			nbytes -= p->size;
			av_packet_free(&p);
		}
	}
};

static double pkt_time(const AVPacket *p, AVRational tb)
{
	int64_t ts = p->dts != AV_NOPTS_VALUE ? p->dts : p->pts;
	return ts == AV_NOPTS_VALUE ? NAN : ts * av_q2d(tb);
}

/* ---------------- input readers ---------------- */

static AVFormatContext *open_input(const char *path)
{
	AVFormatContext *fmt = avformat_alloc_context();
	fmt->interrupt_callback.callback = interrupt_cb;
	AVDictionary *o = nullptr;
	if (strstr(path, "://")) {	/* network: ride out dropped connections on long streams */
		av_dict_set(&o, "reconnect", "1", 0);
		av_dict_set(&o, "reconnect_streamed", "1", 0);
		av_dict_set(&o, "reconnect_on_network_error", "1", 0);
		av_dict_set(&o, "reconnect_delay_max", "10", 0);
		av_dict_set(&o, "rw_timeout", "15000000", 0);	/* a read stuck for 15 s fails */
	}
	int r = avformat_open_input(&fmt, path, nullptr, &o);	/* frees fmt on failure */
	av_dict_free(&o);
	if (r < 0) { fprintf(stderr, "cannot open %s\n", path); return nullptr; }
	avformat_find_stream_info(fmt, nullptr);
	return fmt;
}

/* Reads one input on its own thread into the video and/or audio queue, keeping each about
 * `ahead` seconds full (and all together under `cap` bytes). Finishes the queues at the end. */
struct Reader {
	AVFormatContext *fmt = nullptr;
	int vi = -1, ai = -1;
	AVBSFContext *bsf = nullptr;
	PktQueue *vq = nullptr, *aq = nullptr;
	double ahead = 10;
	size_t cap = 32u << 20;
	const char *name = "input";
	std::thread th;
};

static void reader_video(Reader *r, AVPacket *pkt)
{
	AVRational tb = r->fmt->streams[r->vi]->time_base;
	if (!r->bsf) { r->vq->push(av_packet_clone(pkt), pkt_time(pkt, tb)); return; }
	if (av_bsf_send_packet(r->bsf, pkt) < 0) return;	/* pkt NULL drains the filter */
	AVPacket *o = av_packet_alloc();
	while (av_bsf_receive_packet(r->bsf, o) == 0) {
		r->vq->push(o, pkt_time(o, tb));
		o = av_packet_alloc();
	}
	av_packet_free(&o);
}

static bool reader_wants_more(Reader *r)
{
	size_t b = (r->vq ? r->vq->bytes() : 0) + (r->aq ? r->aq->bytes() : 0);
	if (b >= r->cap) return false;
	/* either queue short: read on (an empty video queue must never wait on a full audio one) */
	return (r->vq && r->vq->duration() < r->ahead) || (r->aq && r->aq->duration() < r->ahead);
}

static void reader_main(Reader *r)
{
	AVPacket *pkt = av_packet_alloc();
	while (!stop && !quit_input) {
		if (!reader_wants_more(r)) { usleep(5000); continue; }
		int e = av_read_frame(r->fmt, pkt);
		if (e == AVERROR(EAGAIN)) { usleep(5000); continue; }
		if (e < 0) {
			if (e != AVERROR_EOF && e != AVERROR_EXIT) {
				char msg[128];
				av_strerror(e, msg, sizeof(msg));
				printf("%s: read failed (%s), ending it\n", r->name, msg);
			}
			break;
		}
		if (pkt->stream_index == r->vi) reader_video(r, pkt);
		else if (pkt->stream_index == r->ai) r->aq->push(av_packet_clone(pkt), pkt_time(pkt, r->fmt->streams[r->ai]->time_base));
		av_packet_unref(pkt);
	}
	if (r->bsf && !stop) reader_video(r, nullptr);
	if (r->vq) r->vq->finish();
	if (r->aq) r->aq->finish();
	av_packet_free(&pkt);
}

/* ---------------- clock ---------------- */

/* Stream seconds. The audio thread publishes the position it is playing; before audio is running
 * (or without audio) the clock runs from the wall. Paused while an input refills. */
struct Clock {
	std::mutex m;
	bool audio = false;
	double a_pos = 0, a_wall = 0;
	double a_buf = 0;	/* seconds ALSA held at a_wall: the clock runs no further than that */
	double w_base = 0;	/* stream time = now() - w_base */
	bool started = false, paused = false;
	double frozen = 0;
	std::atomic<bool> need_buffer{false};	/* the audio thread found its queue dry */

	double get_locked() {
		if (!started) return -1e9;
		if (paused) return frozen;
		if (audio) return a_pos + std::min(now() - a_wall, a_buf);
		return now() - w_base;
	}
	double get() { std::lock_guard<std::mutex> l(m); return get_locked(); }
	bool is_paused() { std::lock_guard<std::mutex> l(m); return paused; }
	double frozen_at() { std::lock_guard<std::mutex> l(m); return frozen; }
	void start_paused(double pos) { std::lock_guard<std::mutex> l(m); started = paused = true; frozen = pos; }
	void pause() { std::lock_guard<std::mutex> l(m); if (!paused) { frozen = get_locked(); paused = true; } }
	void resume() {
		std::lock_guard<std::mutex> l(m);
		if (!paused) return;
		double t = now();
		w_base = t - frozen;
		a_pos = frozen;
		a_wall = t;
		a_buf = 1;	/* until the audio thread reports again */
		paused = false;
	}
	void publish(double pos, double buffered) {	/* from the audio thread */
		std::lock_guard<std::mutex> l(m);
		if (paused) return;
		a_pos = pos;
		a_wall = now();
		a_buf = buffered;
		audio = true;
	}
	void audio_end() {	/* the sound has played out: run on from the wall */
		std::lock_guard<std::mutex> l(m);
		if (!audio) return;
		double p = get_locked();
		w_base = now() - p;
		audio = false;
	}
};

/* ---------------- audio thread ---------------- */

struct Audio {
	AVCodecContext *dec = nullptr;
	AVRational tb;
	snd_pcm_t *pcm = nullptr;
	SwrContext *swr = nullptr;
	int rate = 48000;
	PktQueue q;
	std::atomic<bool> go{false};
	uint64_t written = 0;		/* frames handed to ALSA: the index of the next one */
	struct Seg { uint64_t start; double ts; };
	std::deque<Seg> segs;		/* stream time of frame `start`; a new entry only when timestamps jump */
	std::vector<int16_t> ring;	/* the last second written, to replay after a pause empties ALSA */
	size_t ring_cap = 0, ring_pos = 0, ring_fill = 0;	/* in frames */
};

static void ring_put(Audio *a, const int16_t *w, size_t n)
{
	if (n > a->ring_cap) { w += (n - a->ring_cap) * 2; n = a->ring_cap; }
	while (n) {
		size_t k = std::min(n, a->ring_cap - a->ring_pos);
		memcpy(&a->ring[a->ring_pos * 2], w, k * 4);
		a->ring_pos = (a->ring_pos + k) % a->ring_cap;
		a->ring_fill = std::min(a->ring_fill + k, a->ring_cap);
		w += k * 2;
		n -= k;
	}
}

/* Take the newest n frames back off the ring, oldest first. */
static std::vector<int16_t> ring_take(Audio *a, size_t n)
{
	n = std::min(n, a->ring_fill);
	std::vector<int16_t> out(n * 2);
	size_t start = (a->ring_pos + a->ring_cap - n) % a->ring_cap;
	for (size_t i = 0, k = 0; i < n; i += k) {
		size_t p = (start + i) % a->ring_cap;
		k = std::min(n - i, a->ring_cap - p);
		memcpy(&out[i * 2], &a->ring[p * 2], k * 4);
	}
	a->ring_pos = start;
	a->ring_fill -= n;
	return out;
}

/* Stream time of frame idx (idx never goes backwards, so older entries can go). */
static double audio_pos(Audio *a, uint64_t idx)
{
	while (a->segs.size() > 1 && a->segs[1].start <= idx) a->segs.pop_front();
	if (a->segs.empty()) return 0;
	return a->segs.front().ts + ((double)idx - (double)a->segs.front().start) / a->rate;
}

static void audio_publish(Audio *a, Clock *clk)
{
	snd_pcm_sframes_t delay = 0;
	if (snd_pcm_delay(a->pcm, &delay) < 0 || delay < 0) delay = 0;
	uint64_t heard = a->written > (uint64_t)delay ? a->written - delay : 0;
	clk->publish(audio_pos(a, heard), (double)(a->written - heard) / a->rate + 0.02);
}

static bool audio_pause(Audio *a, Clock *clk);

/* Write n frames, following pauses; false when stopping. */
static bool pcm_out(Audio *a, Clock *clk, const int16_t *w, size_t n)
{
	while (n > 0) {
		if (stop) return false;
		if (clk->is_paused() && !audio_pause(a, clk)) return false;
		snd_pcm_sframes_t r = snd_pcm_writei(a->pcm, w, std::min<size_t>(n, 1024));
		if (r < 0) { if (snd_pcm_recover(a->pcm, r, 1) < 0) return false; continue; }
		ring_put(a, w, r);
		w += r * 2;
		n -= r;
		a->written += r;
		audio_publish(a, clk);
	}
	return true;
}

/* The clock paused (an input is refilling). dmix can't pause, so drop what ALSA still holds, wait,
 * then write it again from the ring, starting where the clock froze: the sound may have played on
 * a little past that (a blocked write is only noticed at its end), and the pictures resume there. */
static bool audio_pause(Audio *a, Clock *clk)
{
	snd_pcm_sframes_t delay = 0;
	snd_pcm_state_t state = snd_pcm_state(a->pcm);
	int de = snd_pcm_delay(a->pcm, &delay);
	if (de < 0 || delay < 0 || (uint64_t)delay > a->written) delay = 0;
	snd_pcm_drop(a->pcm);
	double frozen = clk->frozen_at();
	double heard = a->segs.empty() ? frozen : audio_pos(a, a->written - delay);
	double over = heard - frozen;	/* played past the freeze */
	size_t back = delay + (over > 0 && over < 0.5 ? (size_t)(over * a->rate) : 0);
	std::vector<int16_t> again = ring_take(a, back);
	a->written -= again.size() / 2;
	if (verbose)
		printf("audio pause: state %d delay %ld (rc %d), heard %.3f, clock froze at %.3f, replaying %zu frames\n",
		       (int)state, (long)delay, de, heard, frozen, again.size() / 2);
	while (clk->is_paused() && !stop) usleep(5000);
	if (stop) return false;
	snd_pcm_prepare(a->pcm);
	bool ok = pcm_out(a, clk, again.data(), again.size() / 2);
	if (verbose) {
		snd_pcm_sframes_t d2 = 0;
		snd_pcm_delay(a->pcm, &d2);
		printf("audio resume: written %llu delay %ld, heard %.3f, clock %.3f\n", (unsigned long long)a->written,
		       (long)d2, audio_pos(a, a->written - std::min<uint64_t>(a->written, d2)), clk->get());
	}
	return ok;
}

static void audio_main(Audio *a, Clock *clk)
{
	while (!a->go && !stop) usleep(2000);	/* wait for the first picture */
	AVFrame *fr = av_frame_alloc();
	int16_t *out = nullptr;
	int out_cap = 0;
	bool aligned = false;
	for (;;) {
		if (stop) break;
		if (clk->is_paused() && !audio_pause(a, clk)) break;
		/* Wait in short slices so a pause is seen at once: the sound must stop where the clock
		 * froze, not play on to an underrun. Dry for 100 ms (ALSA still holds ~150 ms): ask
		 * the main loop to pause. */
		bool dry = false;
		AVPacket *p = nullptr;
		for (int slices = 0;; slices++) {
			p = a->q.pop_wait_for(0.01, &dry);
			if (!dry || stop || clk->is_paused()) break;
			if (slices >= 10) clk->need_buffer = true;
		}
		if (stop) { av_packet_free(&p); break; }
		if (dry) continue;	/* paused: handled at the top */
		if (avcodec_send_packet(a->dec, p) < 0 && p) { av_packet_free(&p); continue; }
		bool last = !p;
		av_packet_free(&p);
		bool ok = true;
		while (ok && avcodec_receive_frame(a->dec, fr) == 0) {
			int need = swr_get_out_samples(a->swr, fr->nb_samples);
			if (need > out_cap) { av_free(out); out = (int16_t *)av_malloc(need * 4); out_cap = need; }
			uint8_t *o[1] = { (uint8_t *)out };
			int n = swr_convert(a->swr, o, need, (const uint8_t **)fr->extended_data, fr->nb_samples);
			if (n <= 0) continue;
			int64_t bt = fr->best_effort_timestamp;
			double expect = a->segs.empty() ? 0 :
				a->segs.back().ts + ((double)a->written - (double)a->segs.back().start) / a->rate;
			double ts = bt != AV_NOPTS_VALUE ? bt * av_q2d(a->tb) : expect;
			int16_t *w = out;
			if (!aligned) {	/* line the sound up with the first picture */
				double c = clk->get();
				if (ts + (double)n / a->rate <= c) continue;	/* all of it before the picture */
				if (ts < c) {
					int skip = std::min(n, (int)((c - ts) * a->rate));
					w += skip * 2;
					n -= skip;
					ts += (double)skip / a->rate;
				} else if (ts - c > 0.005 && ts - c < 5) {	/* starts later: silence until then */
					std::vector<int16_t> z((size_t)((ts - c) * a->rate) * 2, 0);
					a->segs.push_back({ a->written, c });
					ok = pcm_out(a, clk, z.data(), z.size() / 2);
				}
				aligned = true;
				expect = NAN;
			}
			if (a->segs.empty() || !(fabs(ts - expect) < 0.002)) a->segs.push_back({ a->written, ts });
			if (ok) ok = pcm_out(a, clk, w, n);
		}
		if (!ok || last) break;
	}
	if (!stop) snd_pcm_drain(a->pcm);
	clk->audio_end();
	av_free(out);
	av_frame_free(&fr);
}

static bool audio_open(Audio &a, AVStream *s)
{
	const AVCodec *c = avcodec_find_decoder(s->codecpar->codec_id);
	if (!c) return false;
	a.dec = avcodec_alloc_context3(c);
	avcodec_parameters_to_context(a.dec, s->codecpar);
	a.dec->pkt_timebase = s->time_base;
	if (avcodec_open2(a.dec, c, nullptr) < 0) return false;
	a.tb = s->time_base;
	a.rate = a.dec->sample_rate;
	AVChannelLayout stereo;
	av_channel_layout_default(&stereo, 2);
	if (swr_alloc_set_opts2(&a.swr, &stereo, AV_SAMPLE_FMT_S16, a.rate,
				&a.dec->ch_layout, a.dec->sample_fmt, a.rate, 0, nullptr) < 0 || swr_init(a.swr) < 0)
		return false;
	if (snd_pcm_open(&a.pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) return false;
	if (snd_pcm_set_params(a.pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED, 2, a.rate, 1, 250000) < 0)
		return false;
	a.ring_cap = a.rate;	/* one second: ALSA never holds more than 250 ms */
	a.ring.assign(a.ring_cap * 2, 0);
	printf("audio: %s, %d Hz, %d ch -> ALSA default\n", c->name, a.rate, a.dec->ch_layout.nb_channels);
	return true;
}

/* ---------------- main ---------------- */

static uint32_t rate_code(double fps)
{
	struct { double f; uint32_t c; } t[] = {
		{ 23.976, vdecFrameRate23_97 }, { 24, vdecFrameRate24 }, { 25, vdecFrameRate25 },
		{ 29.97, vdecFrameRate29_97 }, { 30, vdecFrameRate30 }, { 50, vdecFrameRate50 },
		{ 59.94, vdecFrameRate59_94 }, { 60, vdecFrameRate60 } };
	uint32_t best = vdecFrameRate23_97;
	double bd = 1e9;
	for (auto &e : t) if (fabs(e.f - fps) < bd) { bd = fabs(e.f - fps); best = e.c; }
	return best;
}

int main(int argc, char **argv)
{
	int scale = -1, timeout = 0;
	double maxtemp = 88;	/* stop if the BCM70015 gets hotter than this */
	double fps_override = 0;
	bool bench = false, noaudio = false;
	double lead = 3.0;	/* seconds of video the card may hold beyond what it has decoded (0 = no limit) */
	double target = 2.0;	/* seconds buffered before starting or resuming */
	const char *path = nullptr, *apath = nullptr;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--scale") && i + 1 < argc) scale = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps_override = atof(argv[++i]);
		else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--maxtemp") && i + 1 < argc) maxtemp = atof(argv[++i]);
		else if (!strcmp(argv[i], "--lead") && i + 1 < argc) lead = atof(argv[++i]);
		else if (!strcmp(argv[i], "--buffer") && i + 1 < argc) target = atof(argv[++i]);
		else if (!strcmp(argv[i], "--audio") && i + 1 < argc) apath = argv[++i];
		else if (!strcmp(argv[i], "--bench")) bench = noaudio = true;
		else if (!strcmp(argv[i], "--noaudio")) noaudio = true;
		else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { fputs(USAGE, stdout); return 0; }
		else path = argv[i];
	}
	if (!path) { fputs(USAGE, stderr); return 2; }
	const double target_max = std::max(8.0, target);

	setvbuf(stdout, NULL, _IOLBF, 0);
	verbose = getenv("CHD_VERBOSE") != nullptr;
	const uint32_t trace_from = getenv("CHD_TRACE") ? atoi(getenv("CHD_TRACE")) : 0;
	FILE *dumpf = getenv("CHD_DUMP") ? fopen(getenv("CHD_DUMP"), "wb") : nullptr;	/* debug: copy of what the card is fed */
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGALRM, on_signal);
	if (timeout) alarm(timeout);
	av_log_set_level(AV_LOG_ERROR);

	/* ---- open the input(s) ---- */
	avformat_network_init();
	AVFormatContext *fmt = open_input(path), *afmt = nullptr;
	if (!fmt) return 1;
	int vi = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
	if (vi < 0) { fprintf(stderr, "no video stream\n"); return 1; }
	AVStream *vs = fmt->streams[vi];
	const AVRational vtb = vs->time_base;
	uint32_t algo;
	const char *bsfname = nullptr;
	switch (vs->codecpar->codec_id) {
	case AV_CODEC_ID_H264: algo = BC_VID_ALGO_H264; bsfname = "h264_mp4toannexb"; break;
	case AV_CODEC_ID_MPEG2VIDEO: algo = BC_VID_ALGO_MPEG2; break;
	default: fprintf(stderr, "video codec %s not supported by this player\n", avcodec_get_name(vs->codecpar->codec_id)); return 1;
	}
	double fps = fps_override ? fps_override : av_q2d(vs->avg_frame_rate);
	if (!(fps > 1 && fps < 121)) fps = av_q2d(vs->r_frame_rate);
	if (!(fps > 1 && fps < 121)) fps = 25;
	printf("file: %s, %s %dx%d, %.3f fps, %.1f s\n", fmt->iformat->name, avcodec_get_name(vs->codecpar->codec_id),
	       vs->codecpar->width, vs->codecpar->height, fps, fmt->duration > 0 ? fmt->duration / 1e6 : 0.0);

	AVBSFContext *bsf = nullptr;
	if (bsfname) {
		av_bsf_alloc(av_bsf_get_by_name(bsfname), &bsf);
		avcodec_parameters_copy(bsf->par_in, vs->codecpar);
		bsf->time_base_in = vs->time_base;
		if (av_bsf_init(bsf) < 0) { fprintf(stderr, "bsf init failed\n"); return 1; }
	}

	Audio a;
	Clock clk;
	int ai = -1;	/* in afmt when there is a separate audio input, else in fmt */
	if (!noaudio && apath) {
		afmt = open_input(apath);
		if (afmt) ai = av_find_best_stream(afmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
		if (ai < 0) printf("audio: nothing playable in %s, continuing without\n", apath);
	} else if (!noaudio) {
		ai = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, vi, nullptr, 0);
	}
	AVFormatContext *ain = afmt ? afmt : fmt;
	if (ai >= 0 && !audio_open(a, ain->streams[ai])) { printf("audio: cannot play, continuing without\n"); ai = -1; }
	/* Only read what we play: an HLS/DASH source lists every variant as a stream. */
	for (unsigned i = 0; i < fmt->nb_streams; i++)
		if ((int)i != vi && (afmt || (int)i != ai)) fmt->streams[i]->discard = AVDISCARD_ALL;
	if (afmt)
		for (unsigned i = 0; i < afmt->nb_streams; i++)
			if ((int)i != ai) afmt->streams[i]->discard = AVDISCARD_ALL;

	/* ---- display and decoder ---- */
	Disp d;
	if (!disp_open(d)) { disp_close(d); return 1; }
	const uint32_t PW = d.mode.hdisplay, PH = d.mode.vdisplay;
	if (scale < 0) scale = PW;
	if (scale > 0 && (uint32_t)scale >= (uint32_t)vs->codecpar->width) scale = 0;	/* only ever shrink */

	HANDLE dev = 0;
	BC_STATUS st = BC_STS_SUCCESS;
	uint32_t mode = DTS_PLAYBACK_MODE | DTS_LOAD_FILE_PLAY_FW | DTS_SKIP_TX_CHK_CPB |
			DTS_DFLT_RESOLUTION(vdecRESOLUTION_720p29_97);
	const uint32_t outsz = 1920 * 1088 * 2;
	uint8_t *yuy2 = (uint8_t *)aligned_alloc(16, outsz);
	const uint32_t CHUNK = 32768;
	uint8_t *stg = (uint8_t *)aligned_alloc(64, CHUNK);
	uint32_t stg_len = 0;
	struct SwsContext *sws = nullptr;
	uint32_t w = vs->codecpar->width, h = vs->codecpar->height, dw = 0, dh = 0, dx = 0, dy = 0;
	uint32_t fed_pkts = 0, stg_pkts = 0;
	uint32_t shown = 0, dropped = 0, decoded = 0, lastnum = 0xffffffff, idle = 0, voff = 0, stalls = 0;
	size_t sent = 0;
	bool flushed = false, ready = false;
	double t_dec = 0, t_conv = 0, t0 = 0, tl = 0, ready_pts = 0, vstart = 0;
	double paused_at = 0, paused_total = 0;	/* wall time spent buffering after the first picture */
	/* Picture times: the pts of every packet sent to the card. Pictures come out in display order,
	 * so each takes the smallest. Without pts on every packet, count frames instead. */
	std::priority_queue<double, std::vector<double>, std::greater<double>> pts_heap;
	std::vector<double> stg_pts;
	bool count_frames = false;
	double last_pts = NAN;
	PktQueue vq;
	Reader rv, ra;
	std::thread *ath = nullptr;
	auto start_buffering = [&](const char *why) {
		clk.pause();
		stalls++;
		target = std::min(target * 2, target_max);
		paused_at = now();
		printf("buffering: %s input ran dry (stall %u), waiting for %.0f s\n", why, stalls, target);
	};

	/* Readers start now, so the input fills while the card loads its firmware. */
	rv.fmt = fmt; rv.vi = vi; rv.bsf = bsf; rv.vq = &vq; rv.name = "video input";
	rv.ahead = ra.ahead = std::max(10.0, 2 * target_max);
	if (ai >= 0 && !afmt) { rv.ai = ai; rv.aq = &a.q; rv.name = "input"; }
	rv.th = std::thread(reader_main, &rv);
	if (ai >= 0 && afmt) {
		ra.fmt = afmt; ra.ai = ai; ra.aq = &a.q; ra.name = "audio input";
		ra.th = std::thread(reader_main, &ra);
	}

#define STEP(call) do { st = call; if (st != BC_STS_SUCCESS) { printf("%s -> %d\n", #call, st); goto out; } } while (0)
	STEP(DtsDeviceOpen(&dev, mode));
	if (scale > 0) {
		BC_SCALING_PARAMS sp;
		memset(&sp, 0, sizeof(sp));
		sp.sWidth = scale;
		if (DtsSetScaleParams(dev, &sp) != BC_STS_SUCCESS) scale = 0;
	}
	STEP(DtsOpenDecoder(dev, BC_STREAM_TYPE_ES));
	STEP(DtsSetVideoParams(dev, algo, FALSE, FALSE, TRUE, 0x80000000 | rate_code(fps)));
	STEP(DtsSetColorSpace(dev, MODE422_YUY2));
	STEP(DtsStartDecoder(dev));
	STEP(DtsStartCapture(dev));
	printf("decoder: card scaling %s, %s, chip %.1f C\n", scale ? "on" : "off",
	       bench ? "benchmark" : ai >= 0 ? (afmt ? "audio clock (separate input)" : "audio clock") : "wall clock",
	       chip_temp(dev));

	vstart = vs->start_time != AV_NOPTS_VALUE ? vs->start_time * av_q2d(vs->time_base) : 0;
	if (ai >= 0) ath = new std::thread(audio_main, &a, &clk);

	while (!stop && idle < 4) {
		const bool demux_eof = vq.finished();

		/* 1. buffering: once paused, resume when every input has read `target` seconds past
		 * the paused point (or ended); pause when the audio thread found its queue dry */
		if (clk.started && !bench) {
			if (clk.is_paused()) {
				double pos = clk.get();
				bool v_ok = demux_eof || vq.latest() >= pos + target;
				bool a_ok = ai < 0 || a.q.finished() || a.q.latest() >= pos + target;
				if (v_ok && a_ok) {
					clk.need_buffer = false;
					clk.resume();
					double waited = now() - paused_at;
					if (shown) paused_total += waited;
					if (stalls || waited > 0.25)
						printf("%s after %.1f s buffering\n", stalls ? "resumed" : "started", waited);
				}
			} else if (ai >= 0 && clk.need_buffer && !a.q.finished()) {
				start_buffering("audio");
			}
		}

		/* 2. feed the card while there is room.
		 * - DtsProcInput never returns "busy": when the library's buffer is full it sleeps and
		 *   retries, and with no pictures being collected meanwhile the card runs out of output
		 *   buffers and both sides wait forever. So only send when DtsTxFreeSize says it fits.
		 * - Send the stream as one continuous run of 32 KB pieces, exactly as the test that works
		 *   does. Packet-sized sends (arbitrary lengths, not multiples of 4) hang the BCM70015.
		 *   Only the very last piece, at the end of the file, may be shorter. */
		for (;;) {
			/* Don't run far ahead of the decoder. With a long backlog (seconds of input queued
			 * while playback is paced) the BCM70015 firmware loses input: pictures go missing
			 * and it reports end of stream early. One packet is one frame for H.264. */
			if (lead > 0 && fed_pkts > decoded + (uint32_t)(lead * fps) + 16) break;
			while (stg_len < CHUNK) {
				AVPacket *p = vq.peek();
				if (!p) break;
				uint32_t take = std::min<uint32_t>(p->size - voff, CHUNK - stg_len);
				memcpy(stg + stg_len, p->data + voff, take);
				stg_len += take;
				voff += take;
				if (voff == (uint32_t)p->size) {
					if (p->pts != AV_NOPTS_VALUE) stg_pts.push_back(p->pts * av_q2d(vtb));
					else if (!count_frames) {
						count_frames = true;
						printf("video: packets without timestamps, timing pictures by frame count\n");
					}
					p = vq.try_pop();
					av_packet_free(&p);
					voff = 0;
					stg_pkts++;
				}
			}
			bool last = demux_eof && !vq.size();
			uint32_t n = stg_len == CHUNK ? CHUNK : (last ? stg_len : 0);
			if (!n || DtsTxFreeSize(dev) < n + 4096) break;
			double tp = now();
			BC_STATUS ps = DtsProcInput(dev, stg, n, 0, FALSE);
			if (verbose && now() - tp > 0.05)
				printf("slow input: %u bytes took %.0f ms (sts %d), fed %zu KB, picture %u\n", n, (now() - tp) * 1e3, ps, sent >> 10, decoded);
			if (ps != BC_STS_SUCCESS) break;
			if (dumpf) fwrite(stg, 1, n, dumpf);
			sent += n;
			stg_len = 0;
			fed_pkts += stg_pkts;	/* count frames only once they have really gone to the card */
			stg_pkts = 0;
			for (double t : stg_pts) pts_heap.push(t);
			stg_pts.clear();
		}
		/* The EOS marker goes through the same ring, and the library sleeps 2 s when it doesn't fit:
		 * wait for room instead of stalling playback for 2 s at the end. */
		if (demux_eof && !vq.size() && !stg_len && !flushed && DtsTxFreeSize(dev) >= 65536) {
			double tf = now();
			DtsFlushInput(dev, 0);
			flushed = true;
			if (verbose) printf("flush after picture %u, fed %zu KB, took %.0f ms, clock %.3f\n", decoded, sent >> 10,
					    (now() - tf) * 1e3, clk.get());
		}

		/* 3. a converted picture is waiting for its moment */
		if (ready) {
			double c = bench ? ready_pts : clk.get();
			double wait = ready_pts - c;
			if (wait > 0.002) { usleep((useconds_t)(std::min(wait, 0.010) * 1e6)); continue; }
			present(d, d.front ^ 1);
			ready = false;
			shown++;
			tl = now();
			if (shown == 1) t0 = tl;
			if (shown % 24 == 0 && chip_temp(dev) > maxtemp) {
				printf("chip at %.1f C, over the %.0f C limit: stopping\n", chip_temp(dev), maxtemp);
				break;
			}
			if (shown % 120 == 0)
				printf("%u shown, %u dropped, %.1f fps; per picture: decode+copy %.1f ms, convert %.1f ms; chip %.1f C\n",
				       shown, dropped, shown > 1 ? (shown - 1) / (tl - t0 - paused_total) : 0.0,
				       t_dec * 1e3 / decoded, t_conv * 1e3 / std::max(shown, 1u), chip_temp(dev));
			continue;
		}

		/* 4. fetch the next decoded picture */
		/* The driver's fetch ignores our timeout and waits up to 2 s for a picture, which would
		 * freeze the whole loop whenever the card runs out of input. Until the flush, only
		 * fetch when a picture is ready. */
		if (!flushed) {
			BC_DTS_STATUS ds;
			memset(&ds, 0, sizeof(ds));
			if (DtsGetDriverStatus(dev, &ds) == BC_STS_SUCCESS && ds.ReadyListCount == 0) {
				/* no picture, nothing left to send, and the next one is overdue: the video
				 * input ran dry. Pause rather than drop everything that arrives late. */
				if (clk.started && !bench && !clk.is_paused() && !demux_eof && !vq.size() && stg_len < CHUNK) {
					double next = count_frames ? vstart + decoded / fps :
						!pts_heap.empty() ? pts_heap.top() : std::isnan(last_pts) ? vstart : last_pts + 1 / fps;
					/* under the drop threshold, so the overdue picture still shows on resume */
					if (clk.get() > next + 0.025) start_buffering("video");
				}
				usleep(2000);
				continue;
			}
		}
		BC_DTS_PROC_OUT o;
		memset(&o, 0, sizeof(o));
		o.PicInfo.width = w;
		o.PicInfo.height = h;
		o.Ybuff = yuy2;
		o.YbuffSz = outsz / 4;
		o.PoutFlags = BC_POUT_FLAGS_SIZE;
		double ta = now();
		st = DtsProcOutput(dev, flushed ? 1000 : 20, &o);
		double tb = now();

		if (st == BC_STS_FMT_CHANGE) {
			if (o.PoutFlags & BC_POUT_FLAGS_PIB_VALID) { w = o.PicInfo.width; h = o.PicInfo.height; }
			double sar = av_q2d(av_guess_sample_aspect_ratio(fmt, vs, nullptr));
			double aspect = (double)vs->codecpar->width * (sar > 0 ? sar : 1) / vs->codecpar->height;
			dw = PW; dh = (uint32_t)(PW / aspect + 0.5);
			if (dh > PH) { dh = PH; dw = (uint32_t)(PH * aspect + 0.5); }
			dw &= ~1u; dh &= ~1u;
			dx = (PW - dw) / 2; dy = (PH - dh) / 2;
			sws = sws_getCachedContext(sws, w, h, AV_PIX_FMT_YUYV422, dw, dh, AV_PIX_FMT_BGR0,
						   (w == dw && h == dh) ? SWS_POINT : SWS_FAST_BILINEAR,
						   nullptr, nullptr, nullptr);
			bool hd = vs->codecpar->height >= 600;
			sws_setColorspaceDetails(sws, sws_getCoefficients(hd ? SWS_CS_ITU709 : SWS_CS_ITU601), 0,
						 sws_getCoefficients(SWS_CS_DEFAULT), 1, 0, 1 << 16, 1 << 16);
			printf("format: card gives %ux%u, shown at %ux%u+%u+%u (%s, %s)\n", w, h, dw, dh, dx, dy,
			       (w == dw && h == dh) ? "convert only" : "convert + scale", hd ? "BT.709" : "BT.601");
			wait_flip(d);
			for (int i = 0; i < 2; i++) memset(d.b[i].map, 0, d.b[i].size);
			continue;
		}
		/* The library reports an empty wait as NO_DATA, not TIMEOUT. It only means "the end"
		 * after the flush, or when the picture carries the EOS flag. */
		if (verbose && (st == BC_STS_TIMEOUT || st == BC_STS_NO_DATA)) {
			static double last_report;
			if (now() - last_report > 1) {
				last_report = now();
				printf("waiting: decoded %u fed_pkts %u vq %zu stg %u eof %d flushed %d txfree %u aq %zu\n", decoded, fed_pkts,
				       vq.size(), stg_len, demux_eof, flushed, DtsTxFreeSize(dev), ai >= 0 ? a.q.size() : 0);
			}
		}
		if (st == BC_STS_TIMEOUT || st == BC_STS_NO_DATA) {
			if (o.PicInfo.flags & VDEC_FLAG_EOS) break;
			if (flushed) idle++;
			continue;
		}
		if (st != BC_STS_SUCCESS) { printf("DtsProcOutput -> %d\n", st); idle++; continue; }
		if (!(o.PoutFlags & BC_POUT_FLAGS_PIB_VALID) || o.PicInfo.picture_number == lastnum || !sws)
			continue;
		if (lastnum != 0xffffffff && o.PicInfo.picture_number != lastnum + 1) {
			uint32_t lost = o.PicInfo.picture_number - lastnum - 1;
			if (verbose)
				printf("picture number jump %u -> %u at picture %u (flags 0x%x)\n", lastnum, o.PicInfo.picture_number,
				       decoded, o.PicInfo.flags);
			/* The library also counts a gap as dropped pictures: their times go too. */
			if (lost < 64 && !(o.PicInfo.flags & VDEC_FLAG_INTERLACED_SRC))
				while (lost-- && !pts_heap.empty()) pts_heap.pop();
		}
		lastnum = o.PicInfo.picture_number;
		idle = 0;
		t_dec += tb - ta;

		double pts;
		if (count_frames) pts = vstart + decoded / fps;
		else if (!pts_heap.empty()) { pts = pts_heap.top(); pts_heap.pop(); }
		else pts = std::isnan(last_pts) ? vstart : last_pts + 1 / fps;
		last_pts = pts;
		if (trace_from && decoded >= trace_from)
			printf("pic %u pts %.3f clock %.3f fed %zu KB eof %d vq %zu aq %zu txfree %u\n", decoded, pts, clk.get(),
			       sent >> 10, demux_eof, vq.size(), ai >= 0 ? a.q.size() : 0, DtsTxFreeSize(dev));
		decoded++;
		if (decoded == 1) {	/* the clock starts on the first picture, paused until buffered */
			clk.start_paused(pts);
			paused_at = now();
			if (bench) clk.resume();
			a.go = true;
		}
		/* too late: skip. At least 50 ms of slack: at 50-60 fps on the 60 Hz panel, 1.5 frames
		 * is under two vblanks, and ordinary flip jitter dropped ~5% of a 720p60 stream. */
		if (!bench && pts < clk.get() - std::max(1.5 / fps, 0.050)) {
			dropped++;
			if (verbose)
				printf("drop #%u: %.0f ms late, fetch took %.0f ms, flushed %d, fed %zu KB\n", decoded - 1,
				       (clk.get() - pts) * 1e3, (tb - ta) * 1e3, flushed, sent >> 10);
			continue;
		}
		if (verbose && tb - ta > 0.06)
			printf("slow fetch #%u: %.0f ms, flushed %d, fed %zu KB\n", decoded - 1, (tb - ta) * 1e3, flushed, sent >> 10);

		wait_flip(d);
		double tc = now();
		int back = d.front ^ 1;
		uint8_t *dst[4] = { d.b[back].map + dy * d.b[back].pitch + dx * 4 };
		int dstride[4] = { (int)d.b[back].pitch };
		/* The BCM70015 stamps a 32-bit marker (the line its picture info block follows) into the luma
		 * of the first four pixels of every picture; the library reads it but leaves it there, which
		 * shows as a dot in the top-left corner. Patch those 8 bytes from the line below. */
		if (h > 1) memcpy(yuy2, yuy2 + w * 2, 8);
		const uint8_t *src[4] = { yuy2 };
		int sstride[4] = { (int)(w * 2) };
		sws_scale(sws, src, sstride, 0, h, dst, dstride);
		t_conv += now() - tc;
		ready = true;
		ready_pts = pts;
	}

	if (dumpf) fclose(dumpf);
	if (verbose && dev) {
		BC_DTS_STATUS ds;
		memset(&ds, 0, sizeof(ds));
		if (DtsGetDriverStatus(dev, &ds) == BC_STS_SUCCESS)
			printf("driver: captured %u dropped %u repeated %u pibmiss %u inputs %u (%llu bytes) busy %u\n",
			       ds.FramesCaptured, ds.FramesDropped, ds.FramesRepeated, ds.PIBMissCount, ds.InputCount,
			       (unsigned long long)ds.InputTotalSize, ds.InputBusyCount);
	}
	printf("done: %u decoded, %u shown, %u dropped", decoded, shown, dropped);
	if (shown > 1)
		printf(", %.1f fps; per picture: decode+copy %.1f ms, convert %.1f ms",
		       (shown - 1) / (tl - t0 - paused_total), t_dec * 1e3 / std::max(decoded, 1u), t_conv * 1e3 / shown);
	if (stalls) printf("; %u stall%s, %.1f s buffering", stalls, stalls > 1 ? "s" : "", paused_total);
	printf("%s\n", stop ? " (stopped)" : "");

out:
	/* Readers first (no more packets), then let the sound play out what it has. */
	quit_input = true;
	if (rv.th.joinable()) rv.th.join();
	if (ra.th.joinable()) ra.th.join();
	/* the audio queue can hold many seconds: keep only what belongs with the pictures shown */
	if (ai >= 0 && !std::isnan(last_pts)) a.q.trim_after(last_pts + 0.5);
	if (ai >= 0) { a.go = true; a.q.finish(); clk.resume(); }
	if (ath) { ath->join(); delete ath; }
	if (dev) {
		DtsStopDecoder(dev);
		DtsCloseDecoder(dev);
		DtsDeviceClose(dev);
	}
	if (sws) sws_freeContext(sws);
	disp_close(d);
	while (AVPacket *p = vq.try_pop()) av_packet_free(&p);
	while (AVPacket *p = a.q.try_pop()) av_packet_free(&p);
	av_bsf_free(&bsf);
	if (a.pcm) snd_pcm_close(a.pcm);
	swr_free(&a.swr);
	avcodec_free_context(&a.dec);
	avformat_close_input(&fmt);
	avformat_close_input(&afmt);
	return 0;
}
