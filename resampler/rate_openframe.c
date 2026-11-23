/* rate_openframe.c: OpenFrame's ALSA rate converter, "openframe": the Speex resampler at its
   quality 5, built in (with SSE2), for 16-bit and 32-bit samples alike.

   From alsa-plugins' pph/rate_speexrate.c (1.2.12), whose copyright and licence are below,
   with these changes for the OpenFrame:
   - one converter, "openframe", at quality 5 (speexrate_medium's), in place of three;
   - S32_LE as well as S16_LE (rate plugin protocol 0x010003), through Speex's float path, so
     the 24 bits of a 24-bit source reach a DAC mixed at 32 bits, rather than being cut to 16
     to be resampled;
   - built with speexdsp's resampler inside (with resample-direct.patch: see build.sh), not
     linked to libspeexdsp.

   Rate converter plugin using Public Parrot Hack
   Copyright (C) 2007 Jean-Marc Valin

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions are
   met:

   1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

   3. The name of the author may not be used to endorse or promote products
   derived from this software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
   IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
   OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
   DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
   INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
   (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
   SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
   HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
   STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
   ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
   POSSIBILITY OF SUCH DAMAGE.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <alsa/asoundlib.h>
#include <alsa/pcm_rate.h>
#include "speex_resampler.h"

#define QUALITY 5

struct rate_src {
	unsigned int channels;
	snd_pcm_format_t format;
	SpeexResamplerState *st;
	float *in, *out;		/* S32: the samples as floats, either side */
	size_t in_len, out_len;		/* (in samples) */
};

static snd_pcm_uframes_t input_frames(void *obj, snd_pcm_uframes_t frames)
{
	spx_uint32_t num, den;
	struct rate_src *rate = obj;

	if (frames == 0)
		return 0;
	speex_resampler_get_ratio(rate->st, &num, &den);
	return (snd_pcm_uframes_t)((frames * num + (den >> 1)) / den);
}

static snd_pcm_uframes_t output_frames(void *obj, snd_pcm_uframes_t frames)
{
	spx_uint32_t num, den;
	struct rate_src *rate = obj;

	if (frames == 0)
		return 0;
	speex_resampler_get_ratio(rate->st, &num, &den);
	return (snd_pcm_uframes_t)((frames * den + (num >> 1)) / num);
}

static void pcm_src_free(void *obj)
{
	struct rate_src *rate = obj;

	if (rate->st) {
		speex_resampler_destroy(rate->st);
		rate->st = NULL;
	}
	free(rate->in);
	free(rate->out);
	rate->in = rate->out = NULL;
	rate->in_len = rate->out_len = 0;
}

/* The ratio is the periods' (as alsa-plugins has it), so that each period in gives exactly a
   period out. With the mixer's periods a multiple of 147 frames at 44.1 kHz (of-audio), the
   common rates give a small ratio (48 kHz: 160/147), and a small table. */
static int pcm_src_init(void *obj, snd_pcm_rate_info_t *info)
{
	struct rate_src *rate = obj;
	int err;

	if (!rate->st || rate->channels != info->channels) {
		if (rate->st)
			speex_resampler_destroy(rate->st);
		rate->channels = info->channels;
		rate->st = speex_resampler_init_frac(rate->channels, info->in.period_size, info->out.period_size,
						     info->in.rate, info->out.rate, QUALITY, &err);
		if (!rate->st)
			return -EINVAL;
	}
	rate->format = info->in.format;
	return 0;
}

static int pcm_src_adjust_pitch(void *obj, snd_pcm_rate_info_t *info)
{
	struct rate_src *rate = obj;

	speex_resampler_set_rate_frac(rate->st, info->in.period_size, info->out.period_size, info->in.rate, info->out.rate);
	return 0;
}

static void pcm_src_reset(void *obj)
{
	struct rate_src *rate = obj;

	speex_resampler_reset_mem(rate->st);
}

/* Room for n samples in *buf (of *len). */
static int room(float **buf, size_t *len, size_t n)
{
	float *b;

	if (n <= *len)
		return 0;
	b = realloc(*buf, n * sizeof(float));
	if (!b)
		return -1;
	*buf = b;
	*len = n;
	return 0;
}

/* Interleaved (SND_PCM_RATE_FLAG_INTERLEAVED): the first channel's area is the frames'. */
static void *frames_at(const snd_pcm_channel_area_t *a, snd_pcm_uframes_t offset)
{
	return (char *)a[0].addr + (a[0].first + offset * a[0].step) / 8;
}

static void pcm_src_convert(void *obj, const snd_pcm_channel_area_t *dst_areas, snd_pcm_uframes_t dst_offset,
			    unsigned int dst_frames, const snd_pcm_channel_area_t *src_areas,
			    snd_pcm_uframes_t src_offset, unsigned int src_frames)
{
	struct rate_src *rate = obj;
	unsigned int ch = rate->channels, in = src_frames, out = dst_frames, i;

	if (rate->format == SND_PCM_FORMAT_S16_LE) {
		speex_resampler_process_interleaved_int(rate->st, frames_at(src_areas, src_offset), &in,
							frames_at(dst_areas, dst_offset), &out);
		return;
	}
	/* S32_LE: as floats on Speex's 16-bit scale (so it clips as the 16-bit path does), with
	   the 24 bits a float holds. */
	const int32_t *s = frames_at(src_areas, src_offset);
	int32_t *d = frames_at(dst_areas, dst_offset);
	if (room(&rate->in, &rate->in_len, (size_t)src_frames * ch) ||
	    room(&rate->out, &rate->out_len, (size_t)dst_frames * ch)) {
		memset(d, 0, (size_t)dst_frames * ch * sizeof(int32_t));
		return;
	}
	for (i = 0; i < src_frames * ch; i++)
		rate->in[i] = s[i] * (1.0f / 65536.0f);
	speex_resampler_process_interleaved_float(rate->st, rate->in, &in, rate->out, &out);
	for (i = 0; i < out * ch; i++) {
		float v = rate->out[i] * 65536.0f;
		d[i] = v >= 2147483520.0f ? INT32_MAX : v <= -2147483648.0f ? INT32_MIN : (int32_t)lrintf(v);
	}
	/* (Speex fills what it's given: anything short is silence, not old samples.) */
	if (out < dst_frames)
		memset(d + out * ch, 0, (size_t)(dst_frames - out) * ch * sizeof(int32_t));
}

static void pcm_src_close(void *obj)
{
	pcm_src_free(obj);
	free(obj);
}

static int get_supported_rates(void *obj, unsigned int *rate_min, unsigned int *rate_max)
{
	*rate_min = *rate_max = 0; /* both unlimited */
	return 0;
}

static int get_supported_formats(void *obj, uint64_t *in_formats, uint64_t *out_formats, unsigned int *flags)
{
	*in_formats = *out_formats = (1ULL << SND_PCM_FORMAT_S16_LE) | (1ULL << SND_PCM_FORMAT_S32_LE);
	*flags = SND_PCM_RATE_FLAG_INTERLEAVED | SND_PCM_RATE_FLAG_SYNC_FORMATS;
	return 0;
}

static void dump(void *obj, snd_output_t *out)
{
	snd_output_printf(out, "Converter: openframe (Speex, quality %d)\n", QUALITY);
}

static const snd_pcm_rate_ops_t pcm_src_ops = {
	.close = pcm_src_close,
	.init = pcm_src_init,
	.free = pcm_src_free,
	.reset = pcm_src_reset,
	.adjust_pitch = pcm_src_adjust_pitch,
	.convert = pcm_src_convert,
	.input_frames = input_frames,
	.output_frames = output_frames,
	.version = SND_PCM_RATE_PLUGIN_VERSION,
	.get_supported_rates = get_supported_rates,
	.dump = dump,
	.get_supported_formats = get_supported_formats,
};

int SND_PCM_RATE_PLUGIN_ENTRY(openframe) (unsigned int version, void **objp, snd_pcm_rate_ops_t *ops)
{
	struct rate_src *rate;

	/* only alsa-lib's that know the formats' callback (0x010003, Trixie's): an older one would
	   hand us S16 alone through convert_s16, which this doesn't have */
	if (version < 0x010003)
		return -EINVAL;
	rate = calloc(1, sizeof(*rate));
	if (!rate)
		return -ENOMEM;
	*objp = rate;
	*ops = pcm_src_ops;
	return 0;
}
