// SPDX-License-Identifier: GPL-2.0
/*
 * V4L2 sensor driver for the FLIR Boson+ MIPI thermal camera, through the ARK
 * Boson Adapter.
 *
 * A MIPI Boson+ sends 640x512 at 60 Hz on two CSI-2 lanes with a 246 MHz clock
 * (492 Mbps per lane), either colourised (UYVY) or as pre-AGC 14-bit data. It
 * runs from the connector's 3.3 V and its own oscillator, and the adapter wires
 * no reset or clock to it, so this driver has no power control.
 *
 * The Boson takes commands on I2C at 0x6a, in FLIR's command protocol wrapped
 * in an I2C frame: 8E A1, a big-endian u16 length, then <sequence><function
 * id><status><arguments>, every field a big-endian u32, with no CRC and no byte
 * stuffing. Replies queue in a FIFO that the host reads back, and an empty FIFO
 * reads 0xFF. Function ids and enum values are those of FLIR's Boson SDK
 * (FunctionCodes.h, EnumTypes.h). Videology's MIT-licensed
 * flir_boson_kernel_module showed the I2C framing and the MIPI start sequence.
 *
 * Everything this driver sets on the Boson is volatile: nothing is written to
 * its flash, so a power cycle brings back the camera's saved settings.
 *
 * Ported from ARK's nv_boson driver for Jetson (ark_jetson_kernel).
 *
 * Copyright (c) 2026, ARK Electronics.
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/jiffies.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/string.h>
#include <linux/unaligned.h>

#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-event.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-mediabus.h>
#include <media/v4l2-subdev.h>

#define BOSON_I2C_ADDR			0x6a

#define BOSON_WIDTH			640
#define BOSON_HEIGHT			512
#define BOSON_LANES			2
#define BOSON_LINK_FREQ			246000000

/* FLIR SDK function ids */
#define BOSON_GETCAMERASN		0x00050002
#define BOSON_GETCAMERAPN		0x00050004
#define BOSON_GETSOFTWAREREV		0x00050022
#define TELEMETRY_SETSTATE		0x00040001
#define TELEMETRY_SETMIPIEMBEDDEDDATATAG	0x0004000b
#define DVO_SETOUTPUTFORMAT		0x00060006
#define DVO_SETTYPE			0x0006000f
#define DVO_GETTYPE			0x00060010
#define DVO_SETMIPISTATE		0x00060024
#define DVO_GETMIPISTATE		0x00060025
#define DVO_SETMIPICLOCKLANEMODE	0x00060026
#define DVO_SETOUTPUTINTERFACE		0x00060028
#define DVO_GETOUTPUTINTERFACE		0x00060029
#define DVOMUX_SETTYPE			0x00330000

/* FLIR SDK enum values */
#define FLR_DISABLE			0
#define FLR_DVO_YCBCR			1
#define FLR_DVO_IR16			3
#define FLR_DVO_TYPE_COLOR		2
#define FLR_DVO_TYPE_MONO14		5
#define FLR_DVO_MIPI			1
#define FLR_DVO_MIPI_STATE_OFF		0
#define FLR_DVO_MIPI_STATE_ACTIVE	2
#define FLR_DVO_MIPI_CLOCK_NON_CONTINUOUS	0
#define FLR_DVO_MIPI_CLOCK_CONTINUOUS	1
#define FLR_DVOMUX_OUTPUT_IF_MIPITX	3
#define FLR_DVOMUX_SRC_IR		0
#define FLR_DVOMUX_TYPE_MONO16		0
#define FLR_DVOMUX_TYPE_COLOR		2

#define BOSON_HDR0			0x8e
#define BOSON_HDR1			0xa1
#define BOSON_MAX_ARGS			3
#define BOSON_MAX_REPLY			64
#define BOSON_FLUSH_READS		32
#define BOSON_BUSY_TIMEOUT_MS		2000
#define BOSON_POLL_US			5000
/*
 * Starting MIPI keeps the Boson busy for about 300 ms. While busy it stretches
 * SCL or NAKs its address, and on the Jetson a read that timed out still
 * clocked out a byte, which can be the reply's first header byte: the reply
 * poll accepts a bare second header byte for that reason, as FLIR's own I2C
 * transport does.
 */
#define BOSON_SLOW_CMD_MS		500

struct boson_format {
	u32 code;
	unsigned int bpp;
	u32 dvo_type;
	u32 out_format;
	u32 mux_type;
};

static const struct boson_format boson_formats[] = {
	/* Post-colorize, in the Boson's current palette. */
	{
		.code = MEDIA_BUS_FMT_UYVY8_1X16,
		.bpp = 16,
		.dvo_type = FLR_DVO_TYPE_COLOR,
		.out_format = FLR_DVO_YCBCR,
		.mux_type = FLR_DVOMUX_TYPE_COLOR,
	},
	/*
	 * Pre-AGC 14-bit. The mux takes MONO16 here: MONO14 fails with
	 * FLR_BAD_OUT_TYPE, and DVO type MONO14 packs the 16-bit IR to RAW14.
	 */
	{
		.code = MEDIA_BUS_FMT_Y14_1X14,
		.bpp = 14,
		.dvo_type = FLR_DVO_TYPE_MONO14,
		.out_format = FLR_DVO_IR16,
		.mux_type = FLR_DVOMUX_TYPE_MONO16,
	},
};

static const s64 boson_link_freq_menu[] = {
	BOSON_LINK_FREQ,
};

struct boson {
	struct device *dev;
	struct i2c_client *client;
	struct v4l2_subdev sd;
	struct media_pad pad;

	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl *pixel_rate;

	u32 clock_mode;
	/*
	 * Replies come back in order through one FIFO, so commands must not
	 * interleave. After probe they are only sent from s_stream, which holds
	 * the active state lock.
	 */
	u32 seq;
};

static inline struct boson *sd_to_boson(struct v4l2_subdev *sd)
{
	return container_of_const(sd, struct boson, sd);
}

static const struct boson_format *boson_find_format(u32 code)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(boson_formats); i++)
		if (boson_formats[i].code == code)
			return &boson_formats[i];
	return &boson_formats[0];
}

static u64 boson_pixel_rate(const struct boson_format *fmt)
{
	return div_u64((u64)BOSON_LINK_FREQ * 2 * BOSON_LANES, fmt->bpp);
}

static int boson_recv(struct boson *boson, u8 *buf, int len)
{
	int ret = i2c_master_recv(boson->client, buf, len);

	if (ret == len)
		return 0;
	return ret < 0 ? ret : -EIO;
}

/*
 * Drain stale replies, such as one to a command that timed out, and wait out
 * a busy Boson.
 */
static int boson_flush(struct boson *boson)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(BOSON_BUSY_TIMEOUT_MS);
	u8 buf[4];
	int reads = 0, err;

	for (;;) {
		err = boson_recv(boson, buf, sizeof(buf));
		if (!err && get_unaligned_be32(buf) == 0xffffffff)
			return 0;
		if (!err && ++reads >= BOSON_FLUSH_READS)
			return -EIO;
		if (time_after(jiffies, deadline))
			return err ? err : -ETIMEDOUT;
		if (err)
			fsleep(BOSON_POLL_US);
	}
}

static int boson_send(struct boson *boson, u32 fn, const u32 *args,
		      unsigned int nargs)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(BOSON_BUSY_TIMEOUT_MS);
	u8 tx[4 + 12 + 4 * BOSON_MAX_ARGS];
	unsigned int len = 12 + 4 * nargs, i;
	int ret;

	if (nargs > BOSON_MAX_ARGS)
		return -EINVAL;

	tx[0] = BOSON_HDR0;
	tx[1] = BOSON_HDR1;
	put_unaligned_be16(len, &tx[2]);
	put_unaligned_be32(++boson->seq, &tx[4]);
	put_unaligned_be32(fn, &tx[8]);
	put_unaligned_be32(0xffffffff, &tx[12]);
	for (i = 0; i < nargs; i++)
		put_unaligned_be32(args[i], &tx[16 + 4 * i]);

	for (;;) {
		ret = i2c_master_send(boson->client, tx, 4 + len);
		if (ret == 4 + len)
			return 0;
		if (ret >= 0)
			return -EIO;
		/* A NAKed address means the Boson is busy. */
		if (ret != -EREMOTEIO || time_after(jiffies, deadline))
			return ret;
		fsleep(BOSON_POLL_US);
	}
}

/*
 * Wait for the reply to the last command and copy up to data_len bytes of its
 * data. Returns the number of bytes copied, or a negative error.
 */
static int boson_reply(struct boson *boson, u32 fn, void *data,
		       unsigned int data_len)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(BOSON_BUSY_TIMEOUT_MS);
	u8 rx[12 + BOSON_MAX_REPLY];
	u8 b;
	u16 len;
	u32 status;
	int err;

	/* An idle FIFO reads 0xff; a busy Boson NAKs or times the read out. */
	for (;;) {
		err = boson_recv(boson, &b, 1);
		if (!err && (b == BOSON_HDR0 || b == BOSON_HDR1))
			break;
		if (!err && b != 0xff) {
			dev_err(boson->dev, "0x%08x: stray byte 0x%02x\n", fn, b);
			return -EPROTO;
		}
		if (time_after(jiffies, deadline)) {
			dev_err(boson->dev, "0x%08x: no reply (%d)\n", fn, err);
			return -ETIMEDOUT;
		}
		fsleep(BOSON_POLL_US);
	}

	/* A bare 0xa1: a read that timed out took the 0x8e. */
	if (b == BOSON_HDR0) {
		err = boson_recv(boson, &b, 1);
		if (!err && b != BOSON_HDR1)
			err = -EPROTO;
	}
	if (!err)
		err = boson_recv(boson, rx, 2);
	if (err) {
		dev_err(boson->dev, "0x%08x: bad reply header (%d)\n", fn, err);
		return err;
	}

	len = get_unaligned_be16(rx);
	if (len < 12 || len > sizeof(rx)) {
		dev_err(boson->dev, "0x%08x: reply length %u\n", fn, len);
		return -EPROTO;
	}
	err = boson_recv(boson, rx, len);
	if (err)
		return err;

	if (get_unaligned_be32(&rx[0]) != boson->seq ||
	    get_unaligned_be32(&rx[4]) != fn) {
		dev_err(boson->dev, "0x%08x: reply is for 0x%08x, sequence %u\n",
			fn, get_unaligned_be32(&rx[4]), get_unaligned_be32(&rx[0]));
		return -EPROTO;
	}
	status = get_unaligned_be32(&rx[8]);
	if (status) {
		dev_err(boson->dev, "0x%08x: status 0x%x\n", fn, status);
		return -EIO;
	}

	if (!data)
		return 0;
	data_len = min_t(unsigned int, data_len, len - 12);
	memcpy(data, &rx[12], data_len);
	return data_len;
}

/* Returns the number of reply data bytes copied, or a negative error. */
static int boson_cmd(struct boson *boson, u32 fn, const u32 *args,
		     unsigned int nargs, void *data, unsigned int data_len,
		     unsigned int settle_ms)
{
	int err;

	err = boson_flush(boson);
	if (!err)
		err = boson_send(boson, fn, args, nargs);
	if (err) {
		dev_err(boson->dev, "0x%08x: I2C error %d\n", fn, err);
		return err;
	}
	if (settle_ms)
		msleep(settle_ms);
	return boson_reply(boson, fn, data, data_len);
}

static int boson_get_u32(struct boson *boson, u32 fn, u32 *val)
{
	u8 buf[4];
	int ret = boson_cmd(boson, fn, NULL, 0, buf, sizeof(buf), 0);

	if (ret < 0)
		return ret;
	if (ret < sizeof(buf))
		return -EPROTO;
	*val = get_unaligned_be32(buf);
	return 0;
}

static int boson_set_u32(struct boson *boson, u32 fn, u32 val,
			 unsigned int settle_ms)
{
	int ret = boson_cmd(boson, fn, &val, 1, NULL, 0, settle_ms);

	return ret < 0 ? ret : 0;
}

/* Set a value the Boson can be slow to change, only when it differs. */
static int boson_update_u32(struct boson *boson, u32 get_fn, u32 set_fn,
			    u32 val)
{
	u32 cur;
	int err = boson_get_u32(boson, get_fn, &cur);

	if (err || cur == val)
		return err;
	return boson_set_u32(boson, set_fn, val, BOSON_SLOW_CMD_MS);
}

static int boson_set_format_on_camera(struct boson *boson,
				      const struct boson_format *fmt)
{
	u32 mux[3] = {
		FLR_DVOMUX_OUTPUT_IF_MIPITX, FLR_DVOMUX_SRC_IR, fmt->mux_type,
	};
	int err;

	err = boson_set_u32(boson, DVO_SETMIPISTATE, FLR_DVO_MIPI_STATE_OFF, 0);
	/*
	 * The formats describe 512 image lines and no embedded data. Telemetry
	 * would add a line, and the MIPI embedded-data tag (on from the factory,
	 * even with telemetry off) sends an embedded-data packet ahead of the
	 * image.
	 */
	if (!err)
		err = boson_set_u32(boson, TELEMETRY_SETSTATE, FLR_DISABLE, 0);
	if (!err)
		err = boson_set_u32(boson, TELEMETRY_SETMIPIEMBEDDEDDATATAG,
				    FLR_DISABLE, 0);
	if (!err)
		err = boson_update_u32(boson, DVO_GETTYPE, DVO_SETTYPE,
				       fmt->dvo_type);
	if (!err)
		err = boson_set_u32(boson, DVO_SETOUTPUTFORMAT, fmt->out_format, 0);
	if (!err)
		err = boson_update_u32(boson, DVO_GETOUTPUTINTERFACE,
				       DVO_SETOUTPUTINTERFACE, FLR_DVO_MIPI);
	if (!err)
		err = boson_set_u32(boson, DVO_SETMIPISTATE,
				    FLR_DVO_MIPI_STATE_OFF, 0);
	/* With no reply data, boson_cmd() returns 0 or an error. */
	if (!err)
		err = boson_cmd(boson, DVOMUX_SETTYPE, mux, ARRAY_SIZE(mux),
				NULL, 0, 0);
	if (!err)
		err = boson_set_u32(boson, DVO_SETMIPICLOCKLANEMODE,
				    boson->clock_mode, 0);
	return err;
}

/*
 * DVO_SETMIPISTATE ACTIVE takes about 300 ms, and its I2C reply did not always
 * arrive on the Jetson. Send it, wait it out, and read the state back; the
 * flush in front of that read drains a late reply.
 */
static int boson_mipi_start(struct boson *boson)
{
	u32 state = FLR_DVO_MIPI_STATE_ACTIVE;
	int err;

	err = boson_flush(boson);
	if (!err)
		err = boson_send(boson, DVO_SETMIPISTATE, &state, 1);
	if (err)
		return err;
	msleep(BOSON_SLOW_CMD_MS);

	err = boson_get_u32(boson, DVO_GETMIPISTATE, &state);
	if (err)
		return err;
	if (state != FLR_DVO_MIPI_STATE_ACTIVE) {
		dev_err(boson->dev, "MIPI state %u after start\n", state);
		return -EIO;
	}
	return 0;
}

static int boson_set_stream(struct v4l2_subdev *sd, int enable)
{
	struct boson *boson = sd_to_boson(sd);
	struct v4l2_subdev_state *state;
	const struct boson_format *fmt;
	int ret;

	state = v4l2_subdev_lock_and_get_active_state(sd);
	if (enable) {
		fmt = boson_find_format(v4l2_subdev_state_get_format(state, 0)->code);
		ret = boson_set_format_on_camera(boson, fmt);
		if (!ret)
			ret = boson_mipi_start(boson);
		/*
		 * rp1-cfe's cleanup after a failed sensor stream-on stops the
		 * PiSP front end's CSI-2 channel even when none is in use, and
		 * oopses on channel -1. Report success instead: the capture
		 * then receives no frames and stops cleanly.
		 */
		if (ret) {
			dev_err(boson->dev, "stream start failed (%d)\n", ret);
			boson_set_u32(boson, DVO_SETMIPISTATE,
				      FLR_DVO_MIPI_STATE_OFF, 0);
			ret = 0;
		}
	} else {
		ret = boson_set_u32(boson, DVO_SETMIPISTATE,
				    FLR_DVO_MIPI_STATE_OFF, 0);
		if (ret)
			dev_err(boson->dev, "failed to stop MIPI (%d)\n", ret);
		ret = 0;
	}
	v4l2_subdev_unlock_state(state);

	return ret;
}

static const struct v4l2_subdev_video_ops boson_video_ops = {
	.s_stream = boson_set_stream,
};

static void boson_update_pad_fmt(const struct boson_format *bfmt,
				 struct v4l2_mbus_framefmt *fmt)
{
	fmt->code = bfmt->code;
	fmt->width = BOSON_WIDTH;
	fmt->height = BOSON_HEIGHT;
	fmt->field = V4L2_FIELD_NONE;
	if (bfmt->code == MEDIA_BUS_FMT_UYVY8_1X16) {
		fmt->colorspace = V4L2_COLORSPACE_SRGB;
		fmt->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
		fmt->quantization = V4L2_QUANTIZATION_DEFAULT;
		fmt->xfer_func = V4L2_XFER_FUNC_DEFAULT;
	} else {
		fmt->colorspace = V4L2_COLORSPACE_RAW;
		fmt->ycbcr_enc = V4L2_YCBCR_ENC_601;
		fmt->quantization = V4L2_QUANTIZATION_FULL_RANGE;
		fmt->xfer_func = V4L2_XFER_FUNC_NONE;
	}
}

static int boson_init_state(struct v4l2_subdev *sd,
			    struct v4l2_subdev_state *state)
{
	boson_update_pad_fmt(&boson_formats[0],
			     v4l2_subdev_state_get_format(state, 0));

	return 0;
}

static int boson_enum_mbus_code(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *state,
				struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index >= ARRAY_SIZE(boson_formats))
		return -EINVAL;

	code->code = boson_formats[code->index].code;

	return 0;
}

static int boson_enum_frame_size(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state,
				 struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index || boson_find_format(fse->code)->code != fse->code)
		return -EINVAL;

	fse->min_width = BOSON_WIDTH;
	fse->max_width = BOSON_WIDTH;
	fse->min_height = BOSON_HEIGHT;
	fse->max_height = BOSON_HEIGHT;

	return 0;
}

static int boson_set_format(struct v4l2_subdev *sd,
			    struct v4l2_subdev_state *state,
			    struct v4l2_subdev_format *fmt)
{
	struct boson *boson = sd_to_boson(sd);
	const struct boson_format *bfmt = boson_find_format(fmt->format.code);

	boson_update_pad_fmt(bfmt, &fmt->format);

	if (fmt->which == V4L2_SUBDEV_FORMAT_ACTIVE)
		__v4l2_ctrl_s_ctrl_int64(boson->pixel_rate,
					 boson_pixel_rate(bfmt));

	*v4l2_subdev_state_get_format(state, 0) = fmt->format;

	return 0;
}

static int boson_get_selection(struct v4l2_subdev *sd,
			       struct v4l2_subdev_state *state,
			       struct v4l2_subdev_selection *sel)
{
	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_NATIVE_SIZE:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.top = 0;
		sel->r.left = 0;
		sel->r.width = BOSON_WIDTH;
		sel->r.height = BOSON_HEIGHT;

		return 0;
	}

	return -EINVAL;
}

static const struct v4l2_subdev_pad_ops boson_pad_ops = {
	.enum_mbus_code = boson_enum_mbus_code,
	.enum_frame_size = boson_enum_frame_size,
	.get_fmt = v4l2_subdev_get_fmt,
	.set_fmt = boson_set_format,
	.get_selection = boson_get_selection,
};

static const struct v4l2_subdev_core_ops boson_core_ops = {
	.subscribe_event = v4l2_ctrl_subdev_subscribe_event,
	.unsubscribe_event = v4l2_event_subdev_unsubscribe,
};

static const struct v4l2_subdev_ops boson_subdev_ops = {
	.core = &boson_core_ops,
	.video = &boson_video_ops,
	.pad = &boson_pad_ops,
};

static const struct v4l2_subdev_internal_ops boson_internal_ops = {
	.init_state = boson_init_state,
};

/* The rates are fixed, so no control has a setter. */
static int boson_set_ctrl(struct v4l2_ctrl *ctrl)
{
	return 0;
}

static const struct v4l2_ctrl_ops boson_ctrl_ops = {
	.s_ctrl = boson_set_ctrl,
};

static int boson_init_controls(struct boson *boson)
{
	struct v4l2_ctrl_handler *hdlr = &boson->ctrl_handler;
	struct v4l2_fwnode_device_properties props;
	u64 rate_min = U64_MAX, rate_max = 0;
	struct v4l2_ctrl *ctrl;
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(boson_formats); i++) {
		u64 rate = boson_pixel_rate(&boson_formats[i]);

		rate_min = min(rate_min, rate);
		rate_max = max(rate_max, rate);
	}

	ret = v4l2_ctrl_handler_init(hdlr, 4);
	if (ret)
		return ret;

	boson->pixel_rate = v4l2_ctrl_new_std(hdlr, &boson_ctrl_ops,
					      V4L2_CID_PIXEL_RATE, rate_min,
					      rate_max, 1,
					      boson_pixel_rate(&boson_formats[0]));

	ctrl = v4l2_ctrl_new_int_menu(hdlr, &boson_ctrl_ops, V4L2_CID_LINK_FREQ,
				      0, 0, boson_link_freq_menu);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	if (hdlr->error) {
		ret = hdlr->error;
		dev_err(boson->dev, "control init failed: %d\n", ret);
		goto error_free_hdlr;
	}

	ret = v4l2_fwnode_device_parse(boson->dev, &props);
	if (ret)
		goto error_free_hdlr;

	ret = v4l2_ctrl_new_fwnode_properties(hdlr, &boson_ctrl_ops, &props);
	if (ret)
		goto error_free_hdlr;

	boson->sd.ctrl_handler = hdlr;

	return 0;

error_free_hdlr:
	v4l2_ctrl_handler_free(hdlr);
	return ret;
}

/* Check the Boson answers, and log what it is. */
static int boson_identify(struct boson *boson)
{
	char pn[33] = { 0 };
	u8 rev[12];
	u32 sn;
	int ret;

	ret = boson_get_u32(boson, BOSON_GETCAMERASN, &sn);
	if (!ret)
		ret = boson_cmd(boson, BOSON_GETCAMERAPN, NULL, 0, pn,
				sizeof(pn) - 1, 0);
	if (ret >= 0)
		ret = boson_cmd(boson, BOSON_GETSOFTWAREREV, NULL, 0, rev,
				sizeof(rev), 0);
	if (ret < 0)
		return ret;
	if (ret < sizeof(rev))
		return -EPROTO;

	dev_info(boson->dev, "Boson SN %u, PN %s, software %u.%u.%u\n", sn,
		 strim(pn), get_unaligned_be32(&rev[0]),
		 get_unaligned_be32(&rev[4]), get_unaligned_be32(&rev[8]));
	return 0;
}

static int boson_parse_dt(struct boson *boson)
{
	struct v4l2_fwnode_endpoint ep = {
		.bus_type = V4L2_MBUS_CSI2_DPHY
	};
	struct fwnode_handle *endpoint;
	unsigned int i;
	int ret;

	endpoint = fwnode_graph_get_next_endpoint(dev_fwnode(boson->dev), NULL);
	if (!endpoint) {
		dev_err(boson->dev, "Failed to find endpoint\n");
		return -EINVAL;
	}

	ret = v4l2_fwnode_endpoint_alloc_parse(endpoint, &ep);
	fwnode_handle_put(endpoint);
	if (ret) {
		dev_err(boson->dev, "Failed to parse endpoint\n");
		return ret;
	}

	if (ep.bus.mipi_csi2.num_data_lanes != BOSON_LANES) {
		dev_err(boson->dev, "Unsupported number of data lanes: %u\n",
			ep.bus.mipi_csi2.num_data_lanes);
		ret = -EINVAL;
		goto done;
	}

	for (i = 0; i < ep.nr_of_link_frequencies; i++)
		if (ep.link_frequencies[i] == BOSON_LINK_FREQ)
			break;
	if (i == ep.nr_of_link_frequencies) {
		dev_err(boson->dev, "link-frequencies must list %d\n",
			BOSON_LINK_FREQ);
		ret = -EINVAL;
		goto done;
	}

	/* The endpoint's clock-noncontinuous picks the Boson's clock-lane mode. */
	boson->clock_mode =
		ep.bus.mipi_csi2.flags & V4L2_MBUS_CSI2_NONCONTINUOUS_CLOCK ?
		FLR_DVO_MIPI_CLOCK_NON_CONTINUOUS : FLR_DVO_MIPI_CLOCK_CONTINUOUS;

done:
	v4l2_fwnode_endpoint_free(&ep);

	return ret;
}

static int boson_probe(struct i2c_client *client)
{
	struct boson *boson;
	int ret;

	if (client->addr != BOSON_I2C_ADDR)
		return -ENODEV;

	boson = devm_kzalloc(&client->dev, sizeof(*boson), GFP_KERNEL);
	if (!boson)
		return -ENOMEM;

	boson->dev = &client->dev;
	boson->client = client;
	v4l2_i2c_subdev_init(&boson->sd, client, &boson_subdev_ops);

	ret = boson_parse_dt(boson);
	if (ret)
		return ret;

	ret = boson_identify(boson);
	if (ret) {
		dev_err(&client->dev, "no Boson answering at 0x%02x (%d)\n",
			client->addr, ret);
		return -ENODEV;
	}

	/* Hold the lanes idle until a stream starts. */
	ret = boson_set_u32(boson, DVO_SETMIPISTATE, FLR_DVO_MIPI_STATE_OFF, 0);
	if (ret)
		dev_warn(&client->dev, "could not stop MIPI (%d)\n", ret);

	ret = boson_init_controls(boson);
	if (ret)
		return ret;

	boson->sd.internal_ops = &boson_internal_ops;
	boson->sd.flags = V4L2_SUBDEV_FL_HAS_DEVNODE | V4L2_SUBDEV_FL_HAS_EVENTS;
	boson->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;

	boson->pad.flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&boson->sd.entity, 1, &boson->pad);
	if (ret) {
		dev_err(&client->dev, "failed to init entity pads: %d\n", ret);
		goto error_handler_free;
	}

	boson->sd.state_lock = boson->ctrl_handler.lock;
	ret = v4l2_subdev_init_finalize(&boson->sd);
	if (ret < 0) {
		dev_err(&client->dev, "subdev init error: %d\n", ret);
		goto error_media_entity;
	}

	ret = v4l2_async_register_subdev_sensor(&boson->sd);
	if (ret < 0) {
		dev_err(&client->dev,
			"failed to register sensor sub-device: %d\n", ret);
		goto error_subdev_cleanup;
	}

	return 0;

error_subdev_cleanup:
	v4l2_subdev_cleanup(&boson->sd);
error_media_entity:
	media_entity_cleanup(&boson->sd.entity);
error_handler_free:
	v4l2_ctrl_handler_free(&boson->ctrl_handler);

	return ret;
}

static void boson_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);

	v4l2_async_unregister_subdev(sd);
	v4l2_subdev_cleanup(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(sd->ctrl_handler);
}

static const struct of_device_id boson_of_ids[] = {
	{ .compatible = "flir,boson-plus" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, boson_of_ids);

static struct i2c_driver boson_i2c_driver = {
	.driver	= {
		.name = "boson",
		.of_match_table	= boson_of_ids,
	},
	.probe	= boson_probe,
	.remove	= boson_remove,
};

module_i2c_driver(boson_i2c_driver);

MODULE_DESCRIPTION("FLIR Boson+ MIPI thermal camera driver for the ARK Boson Adapter");
MODULE_AUTHOR("ARK Electronics");
MODULE_LICENSE("GPL");
