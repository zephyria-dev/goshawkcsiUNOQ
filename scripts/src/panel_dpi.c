// SPDX-License-Identifier: GPL-2.0
/*
 * Generic DPI panel driver — reads display timings from device tree.
 *
 * Use as downstream panel behind a DSI-to-DPI bridge (e.g. TC358762).
 * Compatible: "panel-dpi"
 *
 * Required DT properties:
 *   panel-timing { clock-frequency, hactive, vactive, h/vfront-porch,
 *                  h/vback-porch, h/vsync-len };
 * Optional:
 *   width-mm, height-mm, power-supply
 */

#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regulator/consumer.h>

#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

struct panel_dpi {
	struct drm_panel panel;
	struct drm_display_mode mode;
	struct regulator *supply;
	u32 width_mm;
	u32 height_mm;
};

static inline struct panel_dpi *to_panel_dpi(struct drm_panel *p)
{
	return container_of(p, struct panel_dpi, panel);
}

static int panel_dpi_prepare(struct drm_panel *panel)
{
	struct panel_dpi *p = to_panel_dpi(panel);

	if (p->supply)
		return regulator_enable(p->supply);
	return 0;
}

static int panel_dpi_unprepare(struct drm_panel *panel)
{
	struct panel_dpi *p = to_panel_dpi(panel);

	if (p->supply)
		regulator_disable(p->supply);
	return 0;
}

static int panel_dpi_get_modes(struct drm_panel *panel,
			       struct drm_connector *connector)
{
	struct panel_dpi *p = to_panel_dpi(panel);
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(connector->dev, &p->mode);
	if (!mode)
		return -ENOMEM;

	mode->type |= DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;
	connector->display_info.width_mm = p->width_mm;
	connector->display_info.height_mm = p->height_mm;

	drm_mode_probed_add(connector, mode);
	return 1;
}

static const struct drm_panel_funcs panel_dpi_funcs = {
	.prepare = panel_dpi_prepare,
	.unprepare = panel_dpi_unprepare,
	.get_modes = panel_dpi_get_modes,
};

static int panel_dpi_parse_timing(struct device *dev,
				  struct drm_display_mode *mode)
{
	struct device_node *np;
	u32 clock, hact, hfp, hbp, hsync, vact, vfp, vbp, vsync;
	int ret;

	np = of_get_child_by_name(dev->of_node, "panel-timing");
	if (!np) {
		dev_err(dev, "missing panel-timing node\n");
		return -EINVAL;
	}

	ret  = of_property_read_u32(np, "clock-frequency", &clock);
	ret |= of_property_read_u32(np, "hactive", &hact);
	ret |= of_property_read_u32(np, "hfront-porch", &hfp);
	ret |= of_property_read_u32(np, "hback-porch", &hbp);
	ret |= of_property_read_u32(np, "hsync-len", &hsync);
	ret |= of_property_read_u32(np, "vactive", &vact);
	ret |= of_property_read_u32(np, "vfront-porch", &vfp);
	ret |= of_property_read_u32(np, "vback-porch", &vbp);
	ret |= of_property_read_u32(np, "vsync-len", &vsync);

	of_node_put(np);

	if (ret) {
		dev_err(dev, "incomplete panel-timing (missing properties)\n");
		return -EINVAL;
	}

	mode->clock       = clock / 1000;  /* Hz → kHz */
	mode->hdisplay    = hact;
	mode->hsync_start = hact + hfp;
	mode->hsync_end   = hact + hfp + hsync;
	mode->htotal      = hact + hfp + hsync + hbp;
	mode->vdisplay    = vact;
	mode->vsync_start = vact + vfp;
	mode->vsync_end   = vact + vfp + vsync;
	mode->vtotal      = vact + vfp + vsync + vbp;

	return 0;
}

static int panel_dpi_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct panel_dpi *p;
	int ret;

	p = devm_kzalloc(dev, sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;

	p->supply = devm_regulator_get_optional(dev, "power");
	if (IS_ERR(p->supply)) {
		ret = PTR_ERR(p->supply);
		if (ret == -EPROBE_DEFER)
			return ret;
		p->supply = NULL;
	}

	of_property_read_u32(dev->of_node, "width-mm", &p->width_mm);
	of_property_read_u32(dev->of_node, "height-mm", &p->height_mm);

	ret = panel_dpi_parse_timing(dev, &p->mode);
	if (ret)
		return ret;

	drm_panel_init(&p->panel, dev, &panel_dpi_funcs,
		       DRM_MODE_CONNECTOR_DPI);

	drm_panel_add(&p->panel);

	platform_set_drvdata(pdev, p);

	dev_info(dev, "panel-dpi: %dx%d @ %d kHz\n",
		 p->mode.hdisplay, p->mode.vdisplay, p->mode.clock);

	return 0;
}

static void panel_dpi_remove(struct platform_device *pdev)
{
	struct panel_dpi *p = platform_get_drvdata(pdev);

	drm_panel_remove(&p->panel);
}

static const struct of_device_id panel_dpi_of_match[] = {
	{ .compatible = "panel-dpi" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, panel_dpi_of_match);

static struct platform_driver panel_dpi_driver = {
	.probe  = panel_dpi_probe,
	.remove = panel_dpi_remove,
	.driver = {
		.name           = "panel-dpi",
		.of_match_table = panel_dpi_of_match,
	},
};
module_platform_driver(panel_dpi_driver);

MODULE_DESCRIPTION("Generic DPI panel driver with DT-defined timings");
MODULE_LICENSE("GPL");
