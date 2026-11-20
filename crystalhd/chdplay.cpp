// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Andrew Davison
//
// chdplay: Crystal HD video player for the OpenFrame 2.
//
// Video: libavformat demux -> (h264_mp4toannexb) -> BCM70015, scaled on the card to the panel
//        width -> YUY2 -> libswscale -> XRGB8888 in a KMS dumb buffer, page-flipped on vblank.
// Audio: libavcodec (software) -> libswresample (S16 stereo) -> ALSA, on its own thread.
// Sync:  audio is the master clock; late pictures are dropped, early ones wait.
// FFmpeg dropped its Crystal HD decoders in 2024, so only its demuxers and audio decoders are used.
//
// Usage: sudo chdplay [--scale W|0] [--fps N] [--bench] [--noaudio] [--timeout S] [--lead S]
//                     [--maxtemp C] file|URL
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
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
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

static float chip_temp(HANDLE dev)
{
	float t = 0;
	DtsGetCoreTemperature(dev, &t);
	return t;
}

static std::atomic<bool> stop{false};
static void on_signal(int) { stop = true; }

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

struct PktQueue {
	std::mutex m;
	std::condition_variable cv;
	std::deque<AVPacket *> q;
	bool done = false;

	void push(AVPacket *p) { { std::lock_guard<std::mutex> l(m); q.push_back(p); } cv.notify_one(); }
	void finish() { { std::lock_guard<std::mutex> l(m); done = true; } cv.notify_all(); }
	size_t size() { std::lock_guard<std::mutex> l(m); return q.size(); }
	AVPacket *pop_wait() {	/* nullptr = no more packets */
		std::unique_lock<std::mutex> l(m);
		cv.wait(l, [&] { return !q.empty() || done || stop; });
		if (q.empty()) return nullptr;
		AVPacket *p = q.front();
		q.pop_front();
		return p;
	}
	AVPacket *try_pop() {
		std::lock_guard<std::mutex> l(m);
		if (q.empty()) return nullptr;
		AVPacket *p = q.front();
		q.pop_front();
		return p;
	}
	AVPacket *peek() { std::lock_guard<std::mutex> l(m); return q.empty() ? nullptr : q.front(); }
};

/* ---------------- clock ---------------- */

/* Stream seconds. Audio thread publishes (position, wall time) after each write; before audio
 * is running (or without audio) the clock runs from the wall. */
struct Clock {
	std::mutex m;
	bool audio = false;
	double a_pos = 0, a_wall = 0;
	double w_base = 0;	/* stream time = now() - w_base */
	bool started = false;

	double get() {
		std::lock_guard<std::mutex> l(m);
		if (!started) return -1e9;
		if (audio) return a_pos + (now() - a_wall);
		return now() - w_base;
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
	std::thread th;
	std::atomic<bool> go{false};
	uint64_t written = 0;
	double base = -1;	/* stream time of the first sample */
};

static void audio_main(Audio *a, Clock *clk)
{
	while (!a->go && !stop) usleep(2000);	/* wait for the first picture */
	AVFrame *fr = av_frame_alloc();
	int16_t *out = nullptr;
	int out_cap = 0;
	for (;;) {
		AVPacket *p = a->q.pop_wait();
		if (stop) { av_packet_free(&p); break; }
		if (avcodec_send_packet(a->dec, p) < 0 && p) { av_packet_free(&p); continue; }
		bool last = !p;
		av_packet_free(&p);
		while (avcodec_receive_frame(a->dec, fr) == 0) {
			if (a->base < 0) {
				int64_t ts = fr->best_effort_timestamp;
				a->base = ts == AV_NOPTS_VALUE ? 0 : ts * av_q2d(a->tb);
			}
			int need = swr_get_out_samples(a->swr, fr->nb_samples);
			if (need > out_cap) { av_free(out); out = (int16_t *)av_malloc(need * 4); out_cap = need; }
			uint8_t *o[1] = { (uint8_t *)out };
			int n = swr_convert(a->swr, o, need, (const uint8_t **)fr->extended_data, fr->nb_samples);
			int16_t *w = out;
			while (n > 0 && !stop) {
				snd_pcm_sframes_t r = snd_pcm_writei(a->pcm, w, n);
				if (r < 0) { r = snd_pcm_recover(a->pcm, r, 1); if (r < 0) break; continue; }
				w += r * 2;
				n -= r;
				a->written += r;
				snd_pcm_sframes_t delay = 0;
				if (snd_pcm_delay(a->pcm, &delay) < 0) delay = 0;
				std::lock_guard<std::mutex> l(clk->m);
				clk->a_pos = a->base + (double)(a->written - delay) / a->rate;
				clk->a_wall = now();
				clk->audio = true;
			}
		}
		if (last) break;
	}
	if (!stop) snd_pcm_drain(a->pcm);
	av_free(out);
	av_frame_free(&fr);
}

static bool audio_open(Audio &a, AVStream *s)
{
	const AVCodec *c = avcodec_find_decoder(s->codecpar->codec_id);
	if (!c) return false;
	a.dec = avcodec_alloc_context3(c);
	avcodec_parameters_to_context(a.dec, s->codecpar);
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
	const char *path = nullptr;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--scale") && i + 1 < argc) scale = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps_override = atof(argv[++i]);
		else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--maxtemp") && i + 1 < argc) maxtemp = atof(argv[++i]);
		else if (!strcmp(argv[i], "--lead") && i + 1 < argc) lead = atof(argv[++i]);
		else if (!strcmp(argv[i], "--bench")) bench = noaudio = true;
		else if (!strcmp(argv[i], "--noaudio")) noaudio = true;
		else path = argv[i];
	}
	if (!path) { fprintf(stderr, "usage: %s [--scale W|0] [--fps N] [--bench] [--noaudio] [--timeout S] [--lead S] [--maxtemp C] file|URL\n", argv[0]); return 2; }

	setvbuf(stdout, NULL, _IOLBF, 0);
	const bool verbose = getenv("CHD_VERBOSE") != nullptr;
	const uint32_t trace_from = getenv("CHD_TRACE") ? atoi(getenv("CHD_TRACE")) : 0;
	FILE *dumpf = getenv("CHD_DUMP") ? fopen(getenv("CHD_DUMP"), "wb") : nullptr;	/* debug: copy of what the card is fed */
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGALRM, on_signal);
	if (timeout) alarm(timeout);
	av_log_set_level(AV_LOG_ERROR);

	/* ---- open the file ---- */
	AVFormatContext *fmt = nullptr;
	avformat_network_init();
	if (avformat_open_input(&fmt, path, nullptr, nullptr) < 0) { fprintf(stderr, "cannot open %s\n", path); return 1; }
	avformat_find_stream_info(fmt, nullptr);
	int vi = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
	if (vi < 0) { fprintf(stderr, "no video stream\n"); return 1; }
	AVStream *vs = fmt->streams[vi];
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
	int ai = noaudio ? -1 : av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, vi, nullptr, 0);
	/* Only read what we play: an HLS/DASH source lists every variant as a stream. */
	for (unsigned i = 0; i < fmt->nb_streams; i++)
		if ((int)i != vi && (int)i != ai) fmt->streams[i]->discard = AVDISCARD_ALL;
	if (ai >= 0 && !audio_open(a, fmt->streams[ai])) { printf("audio: cannot play, continuing without\n"); ai = -1; }

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
	uint32_t shown = 0, dropped = 0, decoded = 0, lastnum = 0xffffffff, idle = 0, voff = 0;
	size_t sent = 0;
	bool demux_eof = false, flushed = false, ready = false;
	double t_dec = 0, t_conv = 0, t0 = 0, tl = 0, ready_pts = 0, vstart = 0;
	PktQueue vq;
	AVPacket *pkt = av_packet_alloc();
	std::thread *ath = nullptr;

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
	       bench ? "benchmark" : ai >= 0 ? "audio clock" : "wall clock", chip_temp(dev));

	vstart = vs->start_time != AV_NOPTS_VALUE ? vs->start_time * av_q2d(vs->time_base) : 0;
	if (ai >= 0) ath = new std::thread(audio_main, &a, &clk);

	while (!stop && idle < 4) {
		/* 1. demux ahead, keeping both queues fed */
		/* Keep the audio queue short, but never starve the card: when the video queue is empty,
		 * read on (up to ~30 s of audio packets) until video turns up. Without this a file whose
		 * tail is audio-heavy stops the video feed, and the card holds back its last pictures. */
		while (!demux_eof && vq.size() < 48 && (ai < 0 || a.q.size() < 96 || (vq.size() == 0 && a.q.size() < 1500))) {
			if (av_read_frame(fmt, pkt) < 0) {
				demux_eof = true;
				if (bsf) {	/* drain the filter */
					av_bsf_send_packet(bsf, nullptr);
					AVPacket *o = av_packet_alloc();
					while (av_bsf_receive_packet(bsf, o) == 0) { vq.push(o); o = av_packet_alloc(); }
					av_packet_free(&o);
				}
				if (ai >= 0) a.q.finish();
				break;
			}
			if (pkt->stream_index == vi) {
				if (bsf) {
					av_bsf_send_packet(bsf, pkt);
					AVPacket *o = av_packet_alloc();
					while (av_bsf_receive_packet(bsf, o) == 0) { vq.push(o); o = av_packet_alloc(); }
					av_packet_free(&o);
				} else {
					vq.push(av_packet_clone(pkt));
				}
			} else if (pkt->stream_index == ai) {
				a.q.push(av_packet_clone(pkt));
			}
			av_packet_unref(pkt);
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
				       shown, dropped, shown > 1 ? (shown - 1) / (tl - t0) : 0.0,
				       t_dec * 1e3 / decoded, t_conv * 1e3 / std::max(shown, 1u), chip_temp(dev));
			continue;
		}

		/* 4. fetch the next decoded picture */
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
		if (verbose && lastnum != 0xffffffff && o.PicInfo.picture_number != lastnum + 1)
			printf("picture number jump %u -> %u at picture %u (flags 0x%x)\n", lastnum, o.PicInfo.picture_number,
			       decoded, o.PicInfo.flags);
		lastnum = o.PicInfo.picture_number;
		idle = 0;
		t_dec += tb - ta;

		/* pictures come out in display order at a constant rate */
		double pts = vstart + decoded / fps;
		if (trace_from && decoded >= trace_from)
			printf("pic %u pts %.3f clock %.3f fed %zu KB eof %d vq %zu aq %zu txfree %u\n", decoded, pts, clk.get(),
			       sent >> 10, demux_eof, vq.size(), ai >= 0 ? a.q.size() : 0, DtsTxFreeSize(dev));
		decoded++;
		if (decoded == 1) {	/* start the clocks on the first picture */
			std::lock_guard<std::mutex> l(clk.m);
			clk.w_base = now() - pts;
			clk.started = true;
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
		       (shown - 1) / (tl - t0), t_dec * 1e3 / std::max(decoded, 1u), t_conv * 1e3 / shown);
	printf("%s\n", stop ? " (stopped)" : "");

out:
	if (ai >= 0) { a.go = true; a.q.finish(); if (stop) a.q.cv.notify_all(); }
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
	av_packet_free(&pkt);
	av_bsf_free(&bsf);
	if (a.pcm) snd_pcm_close(a.pcm);
	swr_free(&a.swr);
	avcodec_free_context(&a.dec);
	avformat_close_input(&fmt);
	return 0;
}
