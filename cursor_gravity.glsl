// cursor_gravity.glsl — the cursor has mass, for Ghostty
//
// Weak-field (linearized) general relativity reduced to 2D: treat the cursor as a
// point mass that distorts the surrounding terminal texture. Strong-field and nonlinear
// Einstein equations are not solved; we stay in the linear regime g_μν = η_μν + h_μν.
// Ghostty custom shaders have no inter-frame state, so everything is expressed as a
// closed-form analytic function of (current cursor, previous cursor, elapsed time dt).
// Therefore only the most recent jump event can be handled.
//
// Physically faithful aspects:
//   * 2D Poisson lens — the lens potential ψ = θ_E² ln r is the Green's function of
//     the 2D Poisson equation ∇²ψ = 2κ. The deflection angle is its exact gradient
//     α = ∇ψ = θ_E² · r̂/r. Mass is constant (does not grow with speed).
//   * Retarded potential — the field cannot propagate faster than C_LIGHT, so the
//     cursor's motion is not instantaneously known everywhere. Inside the light-speed
//     front r = C_LIGHT·dt, the field points toward the new position; outside, it still
//     points toward the old position (causality).
//   * Quadrupole gravitational wave — a jump is an acceleration impulse → 3+1D quadrupole
//     radiation. We depict it as a slice at the screen plane z=0 (not a 2D wave equation
//     solution; 2+1D GR has no propagating degrees of freedom, so the wave is a projection
//     of the 4D spacetime wave onto the screen). The waveform Q̈ ∝ g′² + g·g″ is derived
//     analytically from the transition trajectory x(t) = jump·g(t/TRANSIT) itself. The shell
//     has thickness c·TRANSIT, amplitude ∝ jump², and spherical geometric decay 1/r. The
//     angular pattern (TT projection of linear motion) is h₊ ∝ sin²θ: zero along the motion
//     axis, two lobes perpendicular. h× vanishes identically by z→−z mirror symmetry.
//   * Sharp spherical shell wavefront — in 3D space Huygens' principle holds: the wave
//     leaves no tail. Only thickness c·TRANSIT, strictly zero outside the shell. The
//     trajectory has zero velocity and acceleration at the endpoints (smootherstep), so
//     there are no shock edges either.
//   * Einstein ring — when a source aligns behind a lens, it produces a ring-shaped image
//     at the Einstein radius θ_E. This is a real lensing phenomenon.
//
// Decorative elements (no physical basis) are explicitly noted in comments below.
//
// Ghostty setup (~/.config/ghostty/config):
//   custom-shader = /path/to/zonvie-cursor-gravity/cursor_gravity.glsl
//   custom-shader-animation = true

// ---------------------------------------------------------------- tunables --
const float REST_MASS    = 0.032;  // Lens strength: Einstein radius θ_E as a fraction of screen height
const float CORE_SIZE    = 0.45;   // Core softening radius a as a fraction of cursor height. Smaller
                                   // tightens the central distortion. Plummer softening parameter
const float LENS_REACH   = 0.55;   // Far-field reach of distortion (fraction of screen height).
                                   // Larger values make the warp wider
const float CHROMA       = 0.020;  // Chromatic aberration: blue bends slightly more than red (pure aesthetics)
const float C_LIGHT      = 1.4;    // Field propagation speed (both retarded front and wave; screen heights/sec)
const float TRANSIT      = 0.070;  // Jump transition time (seconds). This is both the well travel time and the
                                   // duration of the radiated waveform (shell thickness = C_LIGHT·TRANSIT)
const float WAVE_AMP     = 0.0035; // Radiated strain-to-displacement amplitude including lever arm. Effective
                                   // peak displacement ≈ WAVE_AMP·10·jump²/r (Q̈ max ≈ 10, amplitude ∝ jump²)
const float RING_GAIN    = 0.10;   // Brightness of the visible glow/ring (pure decoration)
const float GLOW_RADIUS  = 0.32;   // Glow/ring radius as a fraction of cursor height (<0.5 keeps it inside)
const float BREATH_AMP   = 0.030;  // Slight "breathing" of the rest mass (pure decoration; real masses don't pulsate)
const float MIN_JUMP     = 0.012;  // Moves smaller than this (blinking, jitter) are ignored as events

const float TAU = 6.28318530718;

// Mirrored repeat: avoids edge stretching when the lens references outside the screen
vec2 mirrorUV(vec2 u) { return 1.0 - abs(1.0 - mod(u, 2.0)); }

// pow(x, 2.0) is undefined for x < 0 in GLSL. Gaussian arguments can be negative,
// so always use this for squaring.
float sq(float x) { return x * x; }

// Transition trajectory g(u) = 6u⁵ − 15u⁴ + 10u³ (smootherstep) and derivatives.
// Zero velocity and acceleration at endpoints (g′(0)=g′(1)=g″(0)=g″(1)=0), so the well
// starts and stops smoothly, and the radiated waveform Q̈ ∝ g′² + g·g″ is continuous and
// zero at both ends (no shock edge). The lens retarded position and the gravitational
// waveform are both derived from this same trajectory.
float trajG (float u) { return ((6.0 * u - 15.0) * u + 10.0) * u * u * u; }
float trajG1(float u) { return 30.0 * sq(u * (1.0 - u)); }
float trajG2(float u) { return 60.0 * u * (1.0 - u) * (1.0 - 2.0 * u); }

// Deflection angle of a softened point mass (Plummer distribution):
// α = θ_E² · r / (r² + a²). This is the gradient of the potential ψ = ½θ_E² ln(r²+a²),
// which is the true solution to the 2D Poisson equation. Returns |α|; the direction
// is r̂ (applied by the caller).
//   r → 0 : α → θ_E²·r/a² → 0   … no singularity at center (smooth core when a is small)
//   r = a : α peaks (strongest distortion at r = a = core radius)
//   r ≫ a : α → θ_E²/r          … same 1/r tail as a point mass (wide reach)
// The exp(-(r/reach)²) envelope is the only non-physical term, a soft cutoff for readability.
float deflection(float r, float thetaE, float core, float reach) {
    return thetaE * thetaE * r / (r * r + core * core)
         * exp(-(r * r) / max(reach * reach, 1e-8));
}

// ------------------------------------------------------------------- image --
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2  res    = iResolution.xy;
    vec2  uv     = fragCoord / res;
    float aspect = res.x / res.y;

    // iCurrentCursor: xy = pixel coordinate of cell top-left corner, zw = cell dimensions.
    // Same pixel space as fragCoord/uv. In Ghostty, uv.y is 1 at top, 0 at bottom
    // (fragCoord.y=0 is the screen bottom). The cell's top-left is at high y, so the
    // center is at xy + zw·(0.5, -0.5). If things are off by one cell vertically,
    // flip the sign of CELL_BIAS.y.
    const vec2 CELL_BIAS = vec2(0.5, -0.5);
    vec2 curC  = (iCurrentCursor.xy  + iCurrentCursor.zw  * CELL_BIAS) / res;
    vec2 prevC = (iPreviousCursor.xy + iPreviousCursor.zw * CELL_BIAS) / res;

    vec2  asp   = vec2(aspect, 1.0);     // Aspect correction: scale y to screen-height units
    float dt    = max(0.0, iTime - iTimeCursorChange); // Time since last jump (drives retardation)
    float jump  = length((curC - prevC) * asp);
    float moved = step(MIN_JUMP, jump);

    // ---- Rest mass → 2D lens potential ----
    // Mass is constant. Breathing is pure decoration (real masses don't pulsate).
    float thetaE = REST_MASS * (1.0 + BREATH_AMP * sin(iTime * 2.2));

    vec2  pc = (uv - curC) * asp;    // Offset from current position (used for glow and retardation)
    float rc = length(pc);

    // Core size is tied to the cursor size (tightens central distortion); far reach is
    // measured in screen heights (allows independent tuning of both scales). This is
    // the advantage of the Plummer solution.
    float cellH = iCurrentCursor.w / max(res.y, 1.0);     // Cursor height as fraction of screen
    float core  = max(CORE_SIZE * cellH, 1e-4);           // Core radius a (smaller = tighter center)
    float reach = max(LENS_REACH, 1e-3);                  // Far-field radius (larger = wider warp)
    float front = C_LIGHT * dt;                           // Light-speed front radius = c·dt

    // ---- Retarded potential: where the moving mass appears ----
    // An observer at distance rc sees the mass where it was rc/c seconds ago (retarded time).
    // Model the jump as a mass that transitions from prev to cur over TRANSIT seconds.
    // The apparent mass position is the point along that path corresponding to the retarded
    // time. Thus the well glides behind the light-speed front and is stretched along the
    // path inside the transition shell (true dynamic retardation, not a simple two-valued step).
    float retT = dt - rc / max(C_LIGHT, 1e-4);            // Elapsed time at the retarded moment
    float f    = (moved > 0.0)
               ? trajG(clamp(retT / max(TRANSIT, 1e-4), 0.0, 1.0))  // smootherstep trajectory
               : 1.0;
    vec2  cen  = mix(prevC, curC, f);                    // Retarded position (apparent mass location).
                                                         // The radiated waveform is Q̈ from this same trajectory
    vec2  pr   = (uv - cen) * asp;
    float rr   = length(pr);
    vec2  disp = (pr / max(rr, 1e-5)) * deflection(rr, thetaE, core, reach);

    // ---- Radiated gravitational wave: 3+1D quadrupole radiation sliced at screen plane z=0 ----
    // A jump is an acceleration impulse → quadrupole radiation (amplitude ∝ d²Q/dt²).
    // The wave itself is a 4D spacetime gravitational wave following the retarded Green's
    // function G ∝ δ(t − r/c)/r of the 3D wave equation:
    //   * Huygens' principle holds in 3D → sharp shell (no tail). On the screen: an expanding
    //     ring of thickness one wavelength (one cycle of the bipolar impulse); zero after passing.
    //   * Amplitude is the spherical geometric decay 1/r (quadrupole formula h ∝ Q̈(t − r/c)/r).
    //   * Linear motion quadrupole Q̈ ∝ diag(2/3,−1/3,−1/3) projected to TT gauge in direction n̂(θ)
    //     gives h₊ ∝ sin²θ (zero along motion axis, two lobes perpendicular); h× ≡ 0 by z→−z symmetry.
    //   * TT transverse traceless is in the (in-plane tangent, screen normal) plane. The normal
    //     component (ẑ) is invisible (outside the screen), so only the tangential displacement is
    //     visible. Strain-to-displacement uses a constant lever arm (conventional visualization).
    // Cut off the calculation when the shell's trailing edge exits the screen diagonal (otherwise
    // moved remains 1 forever and the wave runs indefinitely).
    float thick = C_LIGHT * TRANSIT;                    // Shell thickness = c·T
    if (moved > 0.0 && front - thick <= length(asp)) {
        vec2  es = normalize((curC - prevC) * asp);     // Motion axis
        vec2  pe = (uv - mix(prevC, curC, 0.5)) * asp;  // Offset from jump midpoint (event location)
        float re = length(pe);
        vec2  rh = pe / max(re, 1e-5);                  // Radial direction r̂ (propagation direction)
        vec2  th = vec2(-rh.y, rh.x);                   // In-plane tangent t̂ (TT visible axis)

        // Phase u = (t − r/c)/T at the retarded time. The shell expands as re ∈ (c·(dt−T), c·dt),
        // with leading edge re = front and thickness c·T. Outside the window: exactly zero signal
        // (u<0: not yet moving, u>1: already stopped → both have Q̈ = 0).
        float uw  = (dt - re / max(C_LIGHT, 1e-4)) / max(TRANSIT, 1e-4);
        float win = step(0.0, uw) * step(uw, 1.0);
        float u   = clamp(uw, 0.0, 1.0);
        // Quadrupole waveform from the transition trajectory itself: x = jump·g(u), Q ∝ m·x² →
        // Q̈ ∝ (jump²/T²)·(g′² + g·g″). The 1/T² factor is absorbed into WAVE_AMP. Positive during
        // acceleration, negative during deceleration (when jump distance is large). Bipolar: ∫Q̈ du = 0.
        // Magnitude max ≈ 10.
        float qdd = 2.0 * (sq(trajG1(u)) + trajG(u) * trajG2(u));
        // Geometric 1/r decay. The quadrupole formula is valid in the wave zone (r ≳ shell thickness),
        // so cap the near zone.
        float amp = 1.0 / (re + thick);

        float sa  = dot(rh, vec2(-es.y, es.x));         // sin θ (angle to motion axis)
        disp += WAVE_AMP * jump * jump * qdd * win * amp * (sa * sa) * th;
    }

    // ---- Lens sampling (with light chromatic aberration) ----
    vec3 col;
    for (int i = 0; i < 3; i++) {
        float k   = 1.0 + (float(i) - 1.0) * CHROMA;
        vec2  suv = mirrorUV(uv - (disp * k) / asp);
        col[i]    = texture(iChannel0, suv)[i];
    }

    // ---- Visible glow/ring ----
    // Decoupled from the lens strength (thetaE); radius is tied to cursor rectangle height
    // and scaled down by GLOW_RADIUS (<0.5). This keeps the ring and central glow inside
    // the cursor rectangle, avoiding a floating circle. (thetaE is the distortion scale,
    // independent of rectangle size, so this tethering is necessary to align the look.)
    float gr    = max(cellH * GLOW_RADIUS, 1e-4);       // Visible radius (constrained to rectangle)
    vec3  glow  = iCurrentCursorColor.rgb;
    float ring  = exp(-sq((rc - gr) / max(gr * 0.35, 1e-4)));
    col += glow * ring * RING_GAIN;

    // Soft central glow (decays inside the visible radius)
    col += glow * 0.04 * exp(-sq(rc / gr));

    fragColor = vec4(col, 1.0);
}
