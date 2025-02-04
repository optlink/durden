--
-- Implements two kinds of classifiers,
--  [absmouse] = absolution mouse action, cursor follows finger
--  [relmouse] = relative mouse action, cursor follows relative action
--
-- Some further cleaning work here would entail splitting out the
-- multitouch analysis code into its own as well
--
local idevice_log, idevice_fmt = suppl_add_logfn("idevice");
local touchm_evlog = function(msg)
	idevice_log("submodule=touch:classifier=mouse:" .. msg);
end

local function nbits(v)
	local res = 0;
	while(v > 0) do
		res = res + bit.band(v, 1);
		v = bit.rshift(v, 1);
	end
	return res;
end

-- get prefix%d_dir, only l/r/u/d down, no diags..
local function gen_key(dev, prefix, thresh, dx, dy, nf)
	local adx = math.abs(dx);
	local ady = math.abs(dy);

-- now we can set an oscillator for the gesture, or figure out the
-- vector in the non-masked axis
	if (adx > ady) then
		if (adx - ady > thresh) then
			dev.dy_tmp_factor = 0;
			dev.dydt = 0;
			return string.format("%s%d_%s", prefix, nf, dx<0 and "left" or "right");
		end
	else
		if (ady - adx > thresh) then
			dev.dx_tmp_factor = 0;
			dev.dxdt = 0;
			return string.format("%s%d_%s", prefix, nf, dy<0 and "up" or "down");
		end
	end
end

local function run_drag(dev, dx, dy, nf, thresh)

-- special case for mapping to analog mouse wheels, possibly that we should
-- have a scrolling inertia to block small transitions because peoples fingers
-- aren't that precise
	if nf == 2 and dev.drag_2f_analog then
		local basesym;
		if math.abs(dx) > math.abs(dy) then
			dx = dx * dev.drag_2f_analog_factor[1];
			basesym = '/global/input/mouse/scroll/vertical=' .. tostring(dx);
		else
			dy = dy * dev.drag_2f_analog_factor[2];
			basesym = '/global/input/mouse/scroll/horizontal=' .. tostring(dy);
		end
		dispatch_symbol(basesym);
		return true;
	end

	local key = gen_key(dev, "drag", thresh, dx, dy, nf);
	if (not key) then
		return;
	end

	touchm_evlog("device=" .. dev.name .. ":gesture_key=" .. key);

	if (dev.gestures[key]) then
		dispatch_symbol(dev.gestures[key]);
		return true;
	end
end

local function run_swipe(dev, dx, dy, nf)
	local key = gen_key(dev, "swipe", dev.swipe_threshold, dx, dy, nf);
	if (not key) then
		return;
	end

	touchm_evlog("device=" .. dev.name .. ":gesture_key=" .. key);

	if (dev.gestures[key]) then
		dispatch_symbol(dev.gestures[key]);
	end
end

local function memu_digital(devtbl, iotbl)
-- warping is needed for a combination of a touch display that should
-- only give gestures and "touch-press" but have normal behavior with
-- a mouse or trackpad
	local mx, my = mouse_xy();
	touchm_evlog(string.format(
		"device=%d:button=%d:pressed=%d:mask=%d:warp=%d",
		iotbl.devid, iotbl.subid,
		iotbl.active and 1 or 0,
		devtbl.button_mask and 1 or 0,
		devtbl.warp_press and 1 or 0));

-- some buttons should not be forwarded as buttons at all, since they
-- indicate some virtual feature or are just uninteresting, so apply
-- a table for those.
	local bg = devtbl.button_gestures[iotbl.subid];

	if bg then
		local gesture;

-- allow applying gestures both on press and release, if provided as
-- a table, otherwise just assume press and go with that.
		if type(bg) == "table" then
			gesture = bg[iotbl.active and 1 or 2];

		elseif iotbl.active and type(bg) == "string" then
			gesture = bg;
		end

		if gesture then
			touchm_evlog(idevice_fmt("button_gesture:index=%d:gesture=%s", iotbl.subid, gesture));
			if devtbl.gestures[gesture] then
				dispatch_symbol(devtbl.gestures[gesture]);
			end
		end

		return true;
	end

-- otherwise we have button translation to allow certain buttons to
-- become logical mouse buttons (i.e. left, right, middle, wheel, ...)
	iotbl.subid = iotbl.subid ~= 0 and iotbl.subid or 1;
	if (devtbl.button_remap and devtbl.button_remap[iotbl.subid]) then
		iotbl.subid = devtbl.button_remap[iotbl.subid];
	end

-- the button mask is used to not fire button presses on first touch
-- but rather require either a 'tap' gesture or motion then 'click',
-- though if a press has been let through, do the same with the release
		if (devtbl.button_mask and not devtbl.buttons_held[iotbl.subid]) then
		return true;
	end

	if (devtbl.warp_press) then
		mouse_absinput_masked(devtbl.last_x, devtbl.last_y, true);
	end

-- use the ID and modify with an optional "how many fingers on pad" value (can
-- be masked out)
	if (iotbl.subid < MOUSE_AUXBTN) then
		local bc = nbits(devtbl.ind_mask);
		bc = bc > 0 and bc - 1 or bc;
		devtbl.buttons_held[iotbl.subid] = iotbl.active;

-- there might be edge cases here where there are n>1 fingers on the display,
-- and then timeout or hang or reset, leaving the button hanging - if that
-- becomes an issue, keep a list of the button states (or query from the
-- mouse script)
		touchm_evlog(string.format(
			"device=%d:button=%d:active=%d",
			iotbl.devid, iotbl.subid + bc,
			iotbl.active and 1 or 0)
		);
		mouse_button_input(iotbl.subid + bc, iotbl.active);
		iotbl = nil;
	end

-- and warp back to where we were, since this is mouse emulation we
-- might have a rodent there as well that we are messing with
	if (devtbl.warp_press) then
		mouse_absinput_masked(mx, my, true);
	end

	return true;
end

-- aggregate samples with a variable number of ticks as sample period
-- and then feed- back into _input as a relative mouse input event
local function memu_sample(devtbl, iotbl)

-- poorly documented hack, subid is indexed higher for touch to handle
-- devices that emit both emulated mouse and touch events
	local ind = iotbl.subid - 128;

	if (not iotbl.digital) then
-- to work around this for devices that doesn't get classified as touch,
-- we explicit map analog axes to touch indices
		if ind < 0 then
			ind = devtbl.axis_remap[iotbl.subid];
		end

-- still 'fake mouse'? then leave and discard the sample
		if (not ind or ind < 0) then
			return true, nil;
		end
	end

	devtbl.idle = 0;

	if (devtbl.in_idle) then
		touchm_evlog("device=" ..
			tostring(iotbl.devid) .. ":gesture_key=idle_return");
			devtbl.in_idle = false;
		if devtbl.gestures["idle_return"] then
			dispatch_symbol(devtbl.gestures["idle_return"]);
		end
	end

-- digital is bothersome as some devices send the first button as
-- finger on pad even if it has a 'real' button underneath. Then we
-- have 'soft'buttons multitap, and the default behavior for the device
-- in iostatem..
	if (iotbl.digital) then
		if (not devtbl.button_block) then
			return memu_digital(devtbl, iotbl);
		else
			touchm_evlog(string.format(
				"device=%d:status=ignored:button=%d:pressed=%s",
				iotbl.devid, iotbl.subid, iotbl.active and 1 or 0)
			);
		end
		return true, nil;
	end

-- platform or caller filtering, to allow devices lika a PS4 that has a touchpad
-- but also analog axes that we want to handle 'the normal way'
	if (not devtbl.touch and devtbl.touch_only) then
		touchm_evlog(string.format(
			"device=%d:status=forward_notouch", subid.devid));
		return true, iotbl;
	end

	if (not iotbl.x or not iotbl.y) then
		if (iotbl.samples) then
-- something that fakes (or is) a mouse like derivative delivered samples here,
-- need to do the normal "only update on 1" trick
			if (iotbl.subid == 1) then
				iotbl.x = devtbl.cache_x;
				iotbl.y = iotbl.samples[1];
			else
				devtbl.cache_x = iotbl.samples[1];
				return true, nil;
			end
		else
			return true, iotbl;
		end
	end

-- update range
	if (devtbl.autorange) then
		touchm_update_range(devtbl, iotbl);
	end

-- convert to normalized coordinates
	local x = (iotbl.x - devtbl.range[1]) / devtbl.range[3];
	local y = (iotbl.y - devtbl.range[2]) / devtbl.range[4];

-- and account for rotated state
	if devtbl.swap_xy then
		local z = x;
		x = y;
		y = z;
	end

	if devtbl.invert_x then
		x = 1.0 - x;
	end

	if devtbl.invert_y then
		y = 1.0 - y;
	end
-- track sample for auto-reset
	devtbl.last_sample = CLOCK;
	devtbl.reset = false;

-- check for activation, we want a cooldown to this so that the slight
-- delay in multitouch doesn't result in real mouse events
	if (not devtbl.in_active) then
		if (x >= devtbl.activation[1] and x <= devtbl.activation[3] and
			y >= devtbl.activation[2] and y <= devtbl.activation[4]) then
			devtbl.in_active = true;
			devtbl.last_x = x;
			devtbl.last_y = y;
			devtbl.onef_enter = nil;
			devtbl.dxdt = 0;
			devtbl.dydt = 0;
			devtbl.max_ind = 0;
			devtbl.dxyclk = CLOCK;
			devtbl.cooldown = devtbl.default_cooldown;
		end
		return true, nil;
	end

-- detect which fingers have been added or removed
	local im = bit.lshift(1, ind);
	local nm = devtbl.ind_mask;

-- track for the transition to/from single- and multitouch
	if (iotbl.active) then
		nm = bit.bor(devtbl.ind_mask, im);
		if (nm ~= devtbl.ind_mask) then
			if (nbits(nm) == 1) then
				devtbl.primary = nm;
			end
		end
		devtbl.ind_mask = nm;
	else
		nm = bit.band(devtbl.ind_mask, bit.bnot(im));
		if (nm == 0 or (nm == 1 and ind ~= devtbl.primary_ind)) then
			devtbl.in_active = false;
			if (devtbl.mt_enter) then
				if (devtbl.max_ind > 1 and not devtbl.dragged) then
					run_swipe(devtbl, devtbl.dxdt, devtbl.dydt, devtbl.max_ind);
				end
				devtbl.mt_enter = nil;
				devtbl.dragged = false;
				devtbl.max_ind = 0;
			end
		else
			devtbl.last_x = x;
			devtbl.last_y = y;
		end
		devtbl.ind_mask = nm;
		return true, nil;
	end

-- only track delta motion for the first finger, this
-- prevents the classifier from being able to distinguish
-- pinch/zoom style motion
	if (im ~= devtbl.primary) then
		return true, nil;
	end

-- finally figure out the actual motion and scale
	local dx = (x - devtbl.last_x) * devtbl.scale_x;
	local dy = (y - devtbl.last_y) * devtbl.scale_y;
	local nb = nbits(devtbl.ind_mask);

-- release the button mask so that the next 'tap' would register
-- as a button for the absmouse classifier
	devtbl.button_mask = false;

-- track the maximum number of fingers on the pad during a timeslot
-- to detect drag+tap or distinguish between 2/3 finger swipe
	if (devtbl.max_ind < nb) then
		devtbl.max_ind = nb;
	end

	devtbl.last_x = x;
	devtbl.last_y = y;

-- for one-finger drag, map to absolute or relative input, unless
-- "blocked". blocking motion can be useful for touch-displays where
-- presses should warp.
	if (nb == 1 and not devtbl.motion_block) then
		local ad = active_display();
		if (devtbl.cooldown == 0) then
			if (devtbl.abs) then
				mouse_absinput(ad.width * x, ad.height * y);
			else
				mouse_input(ad.width * dx, ad.height * dy);
			end
		else
		end
-- track multi-finger gestures motion separate, this is reset in
-- per timeslot and can be used for magnitude in multi-finger drag
	elseif (nb >= 2 and not devtbl.mt_disable) then
		if (not devtbl.mt_enter) then
			devtbl.mt_enter = CLOCK;
		end

		devtbl.dxdt = devtbl.dx_tmp_factor * (devtbl.dxdt + dx);
		devtbl.dydt = devtbl.dy_tmp_factor * (devtbl.dydt + dy);

-- when we have started one drag and that resulted in a gesture,
-- emit it at a faster rate now
		if devtbl.dragged then
			run_drag(devtbl, devtbl.dxdt, devtbl.dydt, nb, devtbl.drag_step);
		end
	end

	return true, nil;
end

local function memu_init(abs, prof)
-- basic tracking we need
	prof.gest_mask = 0;
	prof.ind_mask = 0;
	prof.last_x = 0;
	prof.last_y = 0;
	prof.dx_tmp_factor = 1;
	prof.dy_tmp_factor = 1;
	prof.last_sample = CLOCK;
	prof.buttons_held = {};
	touchm_evlog(string.format("init, abs=%s", tostring(abs)));
	prof.abs = abs;
end

local function memu_tick(v)
-- this captures 1,2,3+ button drag actions

	if (v.in_active) then
		if (v.cooldown > 0) then
			v.cooldown = v.cooldown - 1;
			if v.cooldown == 0 then
				touchm_evlog("kind=cooldown_over:device=" .. v.name);
			end
		end

	if (v.mt_enter and CLOCK - v.mt_enter >= v.mt_eval) then
-- check if dxdt exceeds threshold, and if so, convert to gesture
-- otherwise reset dxdt and drop mt_enter
			local nb = nbits(v.ind_mask);
			if (nb == 2 or nb == 3) then
				v.dragged = run_drag(v, v.dxdt, v.dydt, nb, v.drag_threshold);
			end
			v.mt_enter = CLOCK;
			v.dxdt = 0;
			v.dydt = 0;
		end
	end

	if (not v.reset and CLOCK - v.last_sample > v.timeout) then
		v.in_active = false;
		v.ind_mask = 0;
		v.dragged = false;
		v.mt_enter = nil;
--		v.button_mask = true; removed to always accept digital buttons
--		regardless of activation zone
		v.dx_tmp_factor = 1;
		v.dy_tmp_factor = 1;
		v.got_tap = false;
		v.reset = true;
		touchm_evlog("kind=timeout_reset:device=" .. v.name);
	end
end

return
{
relmouse = {
	init = function(...)
		memu_init(false, ...);
	end,
	label = "Relative",
	description = "Motion will be translated to relative motion in the mouse cursor",
	sample = memu_sample,
	tick = memu_tick,
	gestures = {},
	menu = nil
},
absmouse = {
	init =
	function(...)
		memu_init(true, ...);
	end,
	label = "Absolute",
	description = "Motion will be mapped to warping the mouse cursor to the sample coordinate",
	sample = memu_sample,
	tick = memu_tick,
	gestures = {},
	menu = nil
}};
