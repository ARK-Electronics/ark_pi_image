// SPDX-License-Identifier: GPL-2.0
/*
 * V4L2 sensor driver for the OmniVision OV64B40, the visible camera of a FLIR
 * Hadron 640R.
 *
 * The Hadron runs the sensor from its own 24 MHz oscillator and its own power,
 * and shares the sensor's reset with its thermal core. The carrier's camera
 * enable drives that reset on the ARK Hadron Adapter: it is the vdd supply
 * here, which the overlay keeps on for good so the thermal core never resets,
 * and stopping a stream only puts the sensor in software standby.
 *
 * Based on ov64a40.c,
 * Copyright (C) 2023 Ideas On Board Oy
 * Copyright (C) 2023 Arducam
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>

#include <media/v4l2-cci.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-event.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-mediabus.h>
#include <media/v4l2-subdev.h>

#include "ov64b40_regs.h"

#define OV64B40_XCLK_FREQ		24000000

/* The widest window the tables open. */
#define OV64B40_NATIVE_WIDTH		9280
#define OV64B40_NATIVE_HEIGHT		6976

#define OV64B40_REG_SOFTWARE_RESET	CCI_REG8(0x0103)
#define OV64B40_SOFTWARE_RESET_US	10000
#define OV64B40_RESET_SETTLE_US		10000

#define OV64B40_REG_STREAMING		CCI_REG8(0x0100)

#define OV64B40_REG_CHIP_ID		CCI_REG24(0x300a)
#define OV64B40_CHIP_ID			0x566442

/*
 * Coarse exposure in lines; the tables keep 32 lines of VTS margin. The OV64B
 * phone drivers keep exposure and VTS even, so both move in 2-line steps.
 */
#define OV64B40_REG_EXPOSURE		CCI_REG24(0x3500)
#define OV64B40_EXPOSURE_MIN		16
#define OV64B40_EXPOSURE_MARGIN		32
#define OV64B40_LINE_STEP		2

/* Linear analogue gain in Q8: 0x0100 is 1x, 0x0f80 is 15.5x. */
#define OV64B40_REG_ANALOGUE_GAIN	CCI_REG16(0x3508)
#define OV64B40_ANALOGUE_GAIN_MIN	0x0100
#define OV64B40_ANALOGUE_GAIN_MAX	0x0f80

/* VTS is 24 bits, with bits 23:16 in 0x3840. */
#define OV64B40_REG_VTS_HIGH		CCI_REG8(0x3840)
#define OV64B40_REG_VTS			CCI_REG16(0x380e)
#define OV64B40_VBLANK_MIN		128
#define OV64B40_VTS_MAX			0xfffffe

#define OV64B40_REG_TEST_PATTERN	CCI_REG8(0x50c1)

static const char * const ov64b40_test_pattern_menu[] = {
	"Disabled",
	"Colour bars",
};

static const int ov64b40_test_pattern_val[] = {
	0x00,
	0x01,
};

struct ov64b40_mode {
	unsigned int width;
	unsigned int height;
	struct v4l2_rect crop;		/* the analogue window */
	unsigned int lanes;
	s64 link_freq;
	u64 pixel_rate;
	unsigned int line_length;	/* in pixels at pixel_rate */
	unsigned int vts;
	u32 code;
	const struct cci_reg_sequence *regs;
	unsigned int num_regs;
};

static const struct ov64b40_mode ov64b40_modes[] = {
	{
		.width = 2304,
		.height = 1728,
		.crop = { .left = 0, .top = 16, .width = 9280, .height = 6944 },
		.lanes = 2,
		.link_freq = 399600000,
		/* 0x380c HTS 2112 counts two pixels; VTS 2726 at 20 fps. */
		.pixel_rate = 2112 * 2 * 2726 * 20,
		.line_length = 2112 * 2,
		.vts = 2726,
		.code = MEDIA_BUS_FMT_SRGGB10_1X10,
		.regs = ov64b40_2304x1728_regs,
		.num_regs = ARRAY_SIZE(ov64b40_2304x1728_regs),
	},
};

struct ov64b40 {
	struct device *dev;
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct regmap *cci;

	const struct ov64b40_mode *mode;

	struct clk *xclk;
	struct regulator *vdd;

	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl *exposure;
	struct v4l2_ctrl *vblank;
	struct v4l2_ctrl *hblank;
};

static inline struct ov64b40 *sd_to_ov64b40(struct v4l2_subdev *sd)
{
	return container_of_const(sd, struct ov64b40, sd);
}

static int ov64b40_start_streaming(struct ov64b40 *ov64b40)
{
	const struct ov64b40_mode *mode = ov64b40->mode;
	unsigned long delay;
	int ret;

	ret = pm_runtime_resume_and_get(ov64b40->dev);
	if (ret < 0)
		return ret;

	ret = cci_write(ov64b40->cci, OV64B40_REG_SOFTWARE_RESET, 0x01, NULL);
	if (ret)
		goto error_power_off;
	fsleep(OV64B40_SOFTWARE_RESET_US);

	ret = cci_multi_reg_write(ov64b40->cci, mode->regs, mode->num_regs,
				  NULL);
	if (ret)
		goto error_power_off;

	ret = __v4l2_ctrl_handler_setup(&ov64b40->ctrl_handler);
	if (ret)
		goto error_power_off;

	ret = cci_write(ov64b40->cci, OV64B40_REG_STREAMING, 0x01, NULL);
	if (ret)
		goto error_power_off;

	/* delay: 150 us + exposure time */
	delay = 150 + DIV_ROUND_UP_ULL((u64)mode->line_length *
				       ov64b40->exposure->cur.val,
				       mode->pixel_rate / 1000 / 1000);
	fsleep(delay);

	return 0;

error_power_off:
	/* Power-off leaves the sensor powered, so stop anything the tables started. */
	cci_write(ov64b40->cci, OV64B40_REG_STREAMING, 0x00, NULL);
	pm_runtime_mark_last_busy(ov64b40->dev);
	pm_runtime_put_autosuspend(ov64b40->dev);

	return ret;
}

static int ov64b40_stop_streaming(struct ov64b40 *ov64b40)
{
	int ret;

	ret = cci_write(ov64b40->cci, OV64B40_REG_STREAMING, 0x00, NULL);
	if (ret)
		dev_err(ov64b40->dev, "failed to enter software standby: %d\n", ret);
	pm_runtime_mark_last_busy(ov64b40->dev);
	pm_runtime_put_autosuspend(ov64b40->dev);

	return 0;
}

static int ov64b40_set_stream(struct v4l2_subdev *sd, int enable)
{
	struct ov64b40 *ov64b40 = sd_to_ov64b40(sd);
	struct v4l2_subdev_state *state;
	int ret;

	state = v4l2_subdev_lock_and_get_active_state(sd);
	if (enable)
		ret = ov64b40_start_streaming(ov64b40);
	else
		ret = ov64b40_stop_streaming(ov64b40);
	v4l2_subdev_unlock_state(state);

	return ret;
}

static const struct v4l2_subdev_video_ops ov64b40_video_ops = {
	.s_stream = ov64b40_set_stream,
};

static void ov64b40_update_pad_fmt(const struct ov64b40_mode *mode,
				   struct v4l2_mbus_framefmt *fmt)
{
	fmt->code = mode->code;
	fmt->width = mode->width;
	fmt->height = mode->height;
	fmt->field = V4L2_FIELD_NONE;
	fmt->colorspace = V4L2_COLORSPACE_RAW;
	fmt->quantization = V4L2_QUANTIZATION_FULL_RANGE;
	fmt->xfer_func = V4L2_XFER_FUNC_NONE;
	fmt->ycbcr_enc = V4L2_YCBCR_ENC_601;
}

static int ov64b40_init_state(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state)
{
	ov64b40_update_pad_fmt(&ov64b40_modes[0],
			       v4l2_subdev_state_get_format(state, 0));
	*v4l2_subdev_state_get_crop(state, 0) = ov64b40_modes[0].crop;

	return 0;
}

static int ov64b40_enum_mbus_code(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  struct v4l2_subdev_mbus_code_enum *code)
{
	struct ov64b40 *ov64b40 = sd_to_ov64b40(sd);

	if (code->index)
		return -EINVAL;

	code->code = ov64b40->mode->code;

	return 0;
}

static int ov64b40_enum_frame_size(struct v4l2_subdev *sd,
				   struct v4l2_subdev_state *state,
				   struct v4l2_subdev_frame_size_enum *fse)
{
	const struct ov64b40_mode *mode;

	if (fse->index >= ARRAY_SIZE(ov64b40_modes))
		return -EINVAL;

	mode = &ov64b40_modes[fse->index];
	if (fse->code != mode->code)
		return -EINVAL;

	fse->min_width = mode->width;
	fse->max_width = mode->width;
	fse->min_height = mode->height;
	fse->max_height = mode->height;

	return 0;
}

static int ov64b40_get_selection(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state,
				 struct v4l2_subdev_selection *sel)
{
	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
		sel->r = *v4l2_subdev_state_get_crop(state, 0);

		return 0;

	case V4L2_SEL_TGT_NATIVE_SIZE:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.top = 0;
		sel->r.left = 0;
		sel->r.width = OV64B40_NATIVE_WIDTH;
		sel->r.height = OV64B40_NATIVE_HEIGHT;

		return 0;
	}

	return -EINVAL;
}

static int ov64b40_set_format(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state,
			      struct v4l2_subdev_format *fmt)
{
	struct ov64b40 *ov64b40 = sd_to_ov64b40(sd);
	const struct ov64b40_mode *mode;

	mode = v4l2_find_nearest_size(ov64b40_modes,
				      ARRAY_SIZE(ov64b40_modes),
				      width, height,
				      fmt->format.width, fmt->format.height);

	ov64b40_update_pad_fmt(mode, &fmt->format);

	if (fmt->which == V4L2_SUBDEV_FORMAT_ACTIVE && ov64b40->mode != mode) {
		int vblank_def = mode->vts - mode->height;
		int hblank = mode->line_length - mode->width;

		ov64b40->mode = mode;
		*v4l2_subdev_state_get_crop(state, 0) = mode->crop;

		__v4l2_ctrl_modify_range(ov64b40->vblank, OV64B40_VBLANK_MIN,
					 OV64B40_VTS_MAX - mode->height,
					 OV64B40_LINE_STEP, vblank_def);
		__v4l2_ctrl_s_ctrl(ov64b40->vblank, vblank_def);
		__v4l2_ctrl_modify_range(ov64b40->hblank, hblank, hblank, 1,
					 hblank);
	}

	*v4l2_subdev_state_get_format(state, 0) = fmt->format;

	return 0;
}

static const struct v4l2_subdev_pad_ops ov64b40_pad_ops = {
	.enum_mbus_code = ov64b40_enum_mbus_code,
	.enum_frame_size = ov64b40_enum_frame_size,
	.get_fmt = v4l2_subdev_get_fmt,
	.set_fmt = ov64b40_set_format,
	.get_selection = ov64b40_get_selection,
};

static const struct v4l2_subdev_core_ops ov64b40_core_ops = {
	.subscribe_event = v4l2_ctrl_subdev_subscribe_event,
	.unsubscribe_event = v4l2_event_subdev_unsubscribe,
};

static const struct v4l2_subdev_ops ov64b40_subdev_ops = {
	.core = &ov64b40_core_ops,
	.video = &ov64b40_video_ops,
	.pad = &ov64b40_pad_ops,
};

static const struct v4l2_subdev_internal_ops ov64b40_internal_ops = {
	.init_state = ov64b40_init_state,
};

static int ov64b40_power_on(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct ov64b40 *ov64b40 = sd_to_ov64b40(sd);
	int ret;

	ret = regulator_enable(ov64b40->vdd);
	if (ret)
		return ret;

	ret = clk_prepare_enable(ov64b40->xclk);
	if (ret) {
		regulator_disable(ov64b40->vdd);
		return ret;
	}

	fsleep(OV64B40_RESET_SETTLE_US);

	return 0;
}

static int ov64b40_power_off(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct ov64b40 *ov64b40 = sd_to_ov64b40(sd);

	clk_disable_unprepare(ov64b40->xclk);
	regulator_disable(ov64b40->vdd);

	return 0;
}

static int ov64b40_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct ov64b40 *ov64b40 = container_of(ctrl->handler, struct ov64b40,
					       ctrl_handler);
	int pm_status;
	int ret = 0;

	if (ctrl->id == V4L2_CID_VBLANK) {
		int exp_max = ov64b40->mode->height + ctrl->val
			    - OV64B40_EXPOSURE_MARGIN;
		int exp_val = min(ov64b40->exposure->cur.val, exp_max);

		/* Shortening the exposure to fit writes it, so stop before VTS if that fails. */
		ret = __v4l2_ctrl_modify_range(ov64b40->exposure,
					       ov64b40->exposure->minimum,
					       exp_max, OV64B40_LINE_STEP, exp_val);
		if (ret)
			return ret;
	}

	pm_status = pm_runtime_get_if_active(ov64b40->dev);
	if (!pm_status)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		ret = cci_write(ov64b40->cci, OV64B40_REG_EXPOSURE, ctrl->val,
				NULL);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		ret = cci_write(ov64b40->cci, OV64B40_REG_ANALOGUE_GAIN,
				ctrl->val, NULL);
		break;
	case V4L2_CID_VBLANK: {
		int vts = ctrl->val + ov64b40->mode->height;

		cci_write(ov64b40->cci, OV64B40_REG_VTS, vts & 0xffff, &ret);
		cci_write(ov64b40->cci, OV64B40_REG_VTS_HIGH, vts >> 16, &ret);
		break;
	}
	case V4L2_CID_TEST_PATTERN:
		ret = cci_write(ov64b40->cci, OV64B40_REG_TEST_PATTERN,
				ov64b40_test_pattern_val[ctrl->val], NULL);
		break;
	default:
		dev_err(ov64b40->dev, "Unhandled control: %#x\n", ctrl->id);
		ret = -EINVAL;
		break;
	}

	if (pm_status > 0) {
		pm_runtime_mark_last_busy(ov64b40->dev);
		pm_runtime_put_autosuspend(ov64b40->dev);
	}

	return ret;
}

static const struct v4l2_ctrl_ops ov64b40_ctrl_ops = {
	.s_ctrl = ov64b40_set_ctrl,
};

static int ov64b40_init_controls(struct ov64b40 *ov64b40)
{
	const struct ov64b40_mode *mode = ov64b40->mode;
	struct v4l2_ctrl_handler *hdlr = &ov64b40->ctrl_handler;
	struct v4l2_fwnode_device_properties props;
	struct v4l2_ctrl *ctrl;
	int hblank = mode->line_length - mode->width;
	int ret;

	ret = v4l2_ctrl_handler_init(hdlr, 9);
	if (ret)
		return ret;

	v4l2_ctrl_new_std(hdlr, &ov64b40_ctrl_ops, V4L2_CID_PIXEL_RATE,
			  mode->pixel_rate, mode->pixel_rate, 1,
			  mode->pixel_rate);

	ctrl = v4l2_ctrl_new_int_menu(hdlr, &ov64b40_ctrl_ops,
				      V4L2_CID_LINK_FREQ, 0, 0,
				      &mode->link_freq);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	v4l2_ctrl_new_std_menu_items(hdlr, &ov64b40_ctrl_ops,
				     V4L2_CID_TEST_PATTERN,
				     ARRAY_SIZE(ov64b40_test_pattern_menu) - 1,
				     0, 0, ov64b40_test_pattern_menu);

	ov64b40->exposure = v4l2_ctrl_new_std(hdlr, &ov64b40_ctrl_ops,
					      V4L2_CID_EXPOSURE,
					      OV64B40_EXPOSURE_MIN,
					      mode->vts - OV64B40_EXPOSURE_MARGIN,
					      OV64B40_LINE_STEP,
					      (mode->vts / 2) & ~1);

	ov64b40->hblank = v4l2_ctrl_new_std(hdlr, &ov64b40_ctrl_ops,
					    V4L2_CID_HBLANK, hblank, hblank, 1,
					    hblank);
	if (ov64b40->hblank)
		ov64b40->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	ov64b40->vblank = v4l2_ctrl_new_std(hdlr, &ov64b40_ctrl_ops,
					    V4L2_CID_VBLANK, OV64B40_VBLANK_MIN,
					    OV64B40_VTS_MAX - mode->height,
					    OV64B40_LINE_STEP,
					    mode->vts - mode->height);

	v4l2_ctrl_new_std(hdlr, &ov64b40_ctrl_ops, V4L2_CID_ANALOGUE_GAIN,
			  OV64B40_ANALOGUE_GAIN_MIN, OV64B40_ANALOGUE_GAIN_MAX,
			  1, OV64B40_ANALOGUE_GAIN_MIN);

	if (hdlr->error) {
		ret = hdlr->error;
		dev_err(ov64b40->dev, "control init failed: %d\n", ret);
		goto error_free_hdlr;
	}

	ret = v4l2_fwnode_device_parse(ov64b40->dev, &props);
	if (ret)
		goto error_free_hdlr;

	ret = v4l2_ctrl_new_fwnode_properties(hdlr, &ov64b40_ctrl_ops,
					      &props);
	if (ret)
		goto error_free_hdlr;

	ov64b40->sd.ctrl_handler = hdlr;

	return 0;

error_free_hdlr:
	v4l2_ctrl_handler_free(hdlr);
	return ret;
}

static int ov64b40_identify(struct ov64b40 *ov64b40)
{
	int ret;
	u64 id;

	ret = cci_read(ov64b40->cci, OV64B40_REG_CHIP_ID, &id, NULL);
	if (ret)
		return dev_err_probe(ov64b40->dev, ret,
				     "no answer: is the Hadron powered over USB and out of reset?\n");

	if (id != OV64B40_CHIP_ID) {
		dev_err(ov64b40->dev, "chip id mismatch: %#llx\n", id);
		return -ENODEV;
	}

	dev_dbg(ov64b40->dev, "OV64B40 chip identified: %#llx\n", id);

	return 0;
}

static int ov64b40_parse_dt(struct ov64b40 *ov64b40)
{
	const struct ov64b40_mode *mode = &ov64b40_modes[0];
	struct v4l2_fwnode_endpoint v4l2_fwnode = {
		.bus_type = V4L2_MBUS_CSI2_DPHY
	};
	struct fwnode_handle *endpoint;
	unsigned int i;
	int ret;

	endpoint = fwnode_graph_get_next_endpoint(dev_fwnode(ov64b40->dev),
						  NULL);
	if (!endpoint) {
		dev_err(ov64b40->dev, "Failed to find endpoint\n");
		return -EINVAL;
	}

	ret = v4l2_fwnode_endpoint_alloc_parse(endpoint, &v4l2_fwnode);
	fwnode_handle_put(endpoint);
	if (ret) {
		dev_err(ov64b40->dev, "Failed to parse endpoint\n");
		return ret;
	}

	if (v4l2_fwnode.bus.mipi_csi2.num_data_lanes != mode->lanes) {
		dev_err(ov64b40->dev, "Unsupported number of data lanes: %u\n",
			v4l2_fwnode.bus.mipi_csi2.num_data_lanes);
		ret = -EINVAL;
		goto done;
	}

	for (i = 0; i < v4l2_fwnode.nr_of_link_frequencies; i++)
		if (v4l2_fwnode.link_frequencies[i] == mode->link_freq)
			break;
	if (i == v4l2_fwnode.nr_of_link_frequencies) {
		dev_err(ov64b40->dev, "link-frequencies must list %lld\n",
			mode->link_freq);
		ret = -EINVAL;
	}

done:
	v4l2_fwnode_endpoint_free(&v4l2_fwnode);

	return ret;
}

static int ov64b40_probe(struct i2c_client *client)
{
	struct ov64b40 *ov64b40;
	unsigned long xclk_freq;
	int ret;

	ov64b40 = devm_kzalloc(&client->dev, sizeof(*ov64b40), GFP_KERNEL);
	if (!ov64b40)
		return -ENOMEM;

	ov64b40->dev = &client->dev;
	v4l2_i2c_subdev_init(&ov64b40->sd, client, &ov64b40_subdev_ops);

	ov64b40->cci = devm_cci_regmap_init_i2c(client, 16);
	if (IS_ERR(ov64b40->cci)) {
		dev_err(&client->dev, "Failed to initialize CCI\n");
		return PTR_ERR(ov64b40->cci);
	}

	/* The Hadron's own oscillator clocks the sensor; a DT clock only states its rate. */
	ov64b40->xclk = devm_clk_get_optional(&client->dev, NULL);
	if (IS_ERR(ov64b40->xclk))
		return dev_err_probe(&client->dev, PTR_ERR(ov64b40->xclk),
				     "Failed to get clock\n");

	xclk_freq = clk_get_rate(ov64b40->xclk);
	if (ov64b40->xclk && xclk_freq != OV64B40_XCLK_FREQ) {
		dev_err(&client->dev, "Unsupported xclk frequency %lu\n",
			xclk_freq);
		return -EINVAL;
	}

	/* Probing defers until the regulator holding the Hadron's reset exists. */
	ov64b40->vdd = devm_regulator_get(&client->dev, "vdd");
	if (IS_ERR(ov64b40->vdd))
		return dev_err_probe(&client->dev, PTR_ERR(ov64b40->vdd),
				     "Failed to get vdd regulator\n");

	ret = ov64b40_parse_dt(ov64b40);
	if (ret)
		return ret;

	ret = ov64b40_power_on(&client->dev);
	if (ret)
		return ret;

	ret = ov64b40_identify(ov64b40);
	if (ret)
		goto error_poweroff;

	ov64b40->mode = &ov64b40_modes[0];

	pm_runtime_set_active(&client->dev);
	pm_runtime_get_noresume(&client->dev);
	pm_runtime_enable(&client->dev);
	pm_runtime_set_autosuspend_delay(&client->dev, 1000);
	pm_runtime_use_autosuspend(&client->dev);

	ret = ov64b40_init_controls(ov64b40);
	if (ret)
		goto error_pm;

	ov64b40->sd.internal_ops = &ov64b40_internal_ops;
	ov64b40->sd.flags = V4L2_SUBDEV_FL_HAS_DEVNODE
			  | V4L2_SUBDEV_FL_HAS_EVENTS;
	ov64b40->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;

	ov64b40->pad.flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&ov64b40->sd.entity, 1, &ov64b40->pad);
	if (ret) {
		dev_err(&client->dev, "failed to init entity pads: %d\n", ret);
		goto error_handler_free;
	}

	ov64b40->sd.state_lock = ov64b40->ctrl_handler.lock;
	ret = v4l2_subdev_init_finalize(&ov64b40->sd);
	if (ret < 0) {
		dev_err(&client->dev, "subdev init error: %d\n", ret);
		goto error_media_entity;
	}

	ret = v4l2_async_register_subdev_sensor(&ov64b40->sd);
	if (ret < 0) {
		dev_err(&client->dev,
			"failed to register sensor sub-device: %d\n", ret);
		goto error_subdev_cleanup;
	}

	pm_runtime_mark_last_busy(&client->dev);
	pm_runtime_put_autosuspend(&client->dev);

	return 0;

error_subdev_cleanup:
	v4l2_subdev_cleanup(&ov64b40->sd);
error_media_entity:
	media_entity_cleanup(&ov64b40->sd.entity);
error_handler_free:
	v4l2_ctrl_handler_free(ov64b40->sd.ctrl_handler);
error_pm:
	pm_runtime_disable(&client->dev);
	pm_runtime_put_noidle(&client->dev);
	pm_runtime_set_suspended(&client->dev);
error_poweroff:
	ov64b40_power_off(&client->dev);

	return ret;
}

static void ov64b40_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);

	v4l2_async_unregister_subdev(sd);
	v4l2_subdev_cleanup(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(sd->ctrl_handler);

	pm_runtime_disable(&client->dev);
	if (!pm_runtime_status_suspended(&client->dev))
		ov64b40_power_off(&client->dev);
	pm_runtime_set_suspended(&client->dev);
}

static const struct of_device_id ov64b40_of_ids[] = {
	{ .compatible = "ovti,ov64b40" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ov64b40_of_ids);

static const struct dev_pm_ops ov64b40_pm_ops = {
	SET_RUNTIME_PM_OPS(ov64b40_power_off, ov64b40_power_on, NULL)
};

static struct i2c_driver ov64b40_i2c_driver = {
	.driver	= {
		.name = "ov64b40",
		.of_match_table	= ov64b40_of_ids,
		.pm = &ov64b40_pm_ops,
	},
	.probe	= ov64b40_probe,
	.remove	= ov64b40_remove,
};

module_i2c_driver(ov64b40_i2c_driver);

MODULE_DESCRIPTION("OmniVision OV64B40 sensor driver for the FLIR Hadron 640R");
MODULE_LICENSE("GPL");
