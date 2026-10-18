/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * Vulkan (MoltenVK) on a CAMetalLayer owned by the embedding application, for
 * Apple platforms without cocoa (iOS, tvOS). The application passes the layer
 * as the `wid` option: `(int64_t)(intptr_t)(__bridge void *)layer`, and keeps
 * it alive while mpv renders into it. The drawable size follows the layer's
 * bounds times its contentsScale; a bounds change wakes the VO, which resizes
 * the swapchain on its next event check.
 */

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

#include "video/out/gpu/context.h"
#include "video/out/vo.h"

#include "common.h"
#include "context.h"
#include "utils.h"

@interface MPVMoltenVKLayerObserver : NSObject {
    struct vo *_vo;
}
- (instancetype)initWithVo:(struct vo *)vo;
@end

@implementation MPVMoltenVKLayerObserver
- (instancetype)initWithVo:(struct vo *)vo
{
    if ((self = [super init]))
        _vo = vo;
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    vo_wakeup(_vo);
}
@end

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
    MPVMoltenVKLayerObserver *observer;
    int width, height;
};

static void layer_pixel_size(CAMetalLayer *layer, int *w, int *h)
{
    CGSize size = layer.bounds.size;
    CGFloat scale = layer.contentsScale;
    *w = (int)(size.width * scale);
    *h = (int)(size.height * scale);
}

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;

    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);

    if (p->observer) {
        [p->layer removeObserver:p->observer forKeyPath:@"bounds"];
        [p->layer removeObserver:p->observer forKeyPath:@"contentsScale"];
        [p->observer release];
        p->observer = nil;
    }
    if (p->layer) {
        [p->layer release];
        p->layer = nil;
    }
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    int64_t wid = ctx->vo->opts->WinID;
    if (wid <= 0) {
        MP_MSG(ctx, msgl, "moltenvk needs --wid set to a CAMetalLayer.\n");
        goto error;
    }
    id object = (__bridge id)(void *)(intptr_t)wid;
    if (![object isKindOfClass:[CAMetalLayer class]]) {
        MP_MSG(ctx, msgl, "--wid is not a CAMetalLayer.\n");
        goto error;
    }
    p->layer = [(CAMetalLayer *)object retain];

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto error;

    VkMetalSurfaceCreateInfoEXT info = {
        .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pLayer = p->layer,
    };

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating Metal surface\n");
        goto error;
    }

    struct ra_ctx_params params = {0};
    if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
        goto error;

    p->observer = [[MPVMoltenVKLayerObserver alloc] initWithVo:ctx->vo];
    [p->layer addObserver:p->observer forKeyPath:@"bounds" options:0 context:NULL];
    [p->layer addObserver:p->observer forKeyPath:@"contentsScale" options:0 context:NULL];

    return true;
error:
    moltenvk_uninit(ctx);
    return false;
}

// Resizes the swapchain to the layer's current pixel size. A layer that is not laid out yet (zero size) keeps the
// old swapchain: its first real bounds wake the VO and the next event check resizes.
static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    int w, h;
    layer_pixel_size(p->layer, &w, &h);
    if (w <= 0 || h <= 0 || (w == p->width && h == p->height))
        return true;
    p->width = w;
    p->height = h;
    return ra_vk_ctx_resize(ctx, w, h);
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;
    if (request != VOCTRL_CHECK_EVENTS)
        return VO_NOTIMPL;

    int old_w = p->width, old_h = p->height;
    if (!moltenvk_reconfig(ctx))
        return VO_ERROR;
    if (p->width != old_w || p->height != old_h)
        *events |= VO_EVENT_RESIZE;
    return VO_TRUE;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .description    = "MoltenVK on a CAMetalLayer passed as --wid (iOS/tvOS)",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};
