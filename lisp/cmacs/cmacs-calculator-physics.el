;;; cmacs-calculator-physics.el --- Physics and relativity calculators -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Physics calculators for `cmacs-calculator', in two categories:
;; `physics' (kinematics, dynamics, energy, momentum, rotation, gravitation,
;; oscillation, thermodynamics, electromagnetism, optics, quantum) and
;; `relativity' (special and general).
;;
;; Everything defined with `cmacs-calculator-defcalc' is a first-class Calc
;; algebraic function, so it composes inside any larger expression:
;;
;;   escapevel(5.972e24, 6.371e6) / 1000        => km/s
;;   reltotale(1, 0.9) - massenergy(1)          => same as relke(1, 0.9)
;;
;; Units: SI, always
;; ------------------
;; Every argument and every result is in base SI units -- metres, kilograms,
;; seconds, kelvin, coulombs, joules -- and every angle is in radians (the
;; engine pins `calc-angle-mode' to `rad').  There is no unit tracking here:
;; these are numeric formulas, and feeding one a value in grams or degrees
;; silently gives an answer in the wrong scale.  For dimensional work, use
;; Calc's units system through `cmacs-calculator-to-base-units' and
;; `cmacs-calculator-convert-units' instead, which do track units.
;;
;; Why Calc's `c', `G' and `h' are not used here
;; ---------------------------------------------
;; Calc does ship CODATA constants, but they are entries in its *units*
;; table, not numbers: `c' is the unit "299792458 m/s", not the integer
;; 299792458.  They therefore stay symbolic under ordinary evaluation --
;; "sqrt(2*G*5.972e24/6.371e6)" evaluates to `1369213255.12 sqrt(G)', not to
;; a velocity -- and only resolve once something converts units.  Since these
;; calculators are plain numeric functions, they use the private Calc floats
;; in the *Physical constants* section below, whose values mirror Calc's own
;; table (verified: `escapevel(5.972e24, 6.371e6)' agrees to all 12 digits
;; with the units-table computation via `cmacs-calculator-to-base-units').
;;
;; Those constants are spelled with a hyphen deliberately.  Calc's `defmath'
;; compiler turns a bare symbol such as `G' into the Calc variable `var-G',
;; but leaves any symbol *containing a hyphen* alone as an ordinary Lisp
;; variable reference -- which is exactly what is wanted, and is why a plain
;; float literal must never appear in a `defmath' body: `defmath' passes
;; Emacs floats through unconverted, and `math-mul' on one yields a value
;; that is not a Calc number and breaks the next operation.
;;
;; Relativity argument convention
;; ------------------------------
;; The gamma-style relativistic functions take speed as BETA, a *fraction of
;; the speed of light*: 0.9 means 0.9c, not 0.9 m/s.  That is the convention
;; the formulas are written in and it keeps them free of huge intermediate
;; magnitudes.  Results that are speeds (`veladd') are likewise fractions of
;; c; results that are momenta or energies (`relmomentum', `relke') come back
;; in SI, since that is what they are for.  Each docstring says which.
;;
;; Rejecting impossible input
;; --------------------------
;; Formulas whose domain is bounded -- beta at or beyond 1, a radius inside
;; the event horizon, a refraction that is really total internal reflection --
;; check their arguments and call `math-reject-arg', the same idiom Calc's own
;; `math-check-financial' uses in `calc-fin.el'.  Calc answers a rejected call
;; by returning it unevaluated (`lorentz(1.5)' => "lorentz(1.5)"), exactly as
;; stock Calc answers `pmt(0, 5, 100)'.  This matters: undefended, `lorentz(1.5)'
;; would quietly return the complex number `(0., -0.894427191)', which looks
;; like a result and is not one.  An argument is checked whenever it folds to a
;; number -- `lorentz(3/2)' and `lorentz(pi/2)' are caught as surely as
;; `lorentz(1.5)' -- while a genuinely free variable passes through unchecked,
;; so symbolic algebra over these functions still composes and
;; `lorentz(b)' is still `1 / sqrt(1 - b^2)'.

;;; Code:

(require 'calc)
(require 'calc-ext)
(require 'cmacs-calculator)

(declare-function math-read-number "calc" (s &optional decimal))
(declare-function math-realp "calc" (a))
(declare-function math-lessp "calc-ext" (a b))
(declare-function math-abs "calc-arith" (a))
(declare-function math-evaluate-expr "calc-alg" (x))
(declare-function math-reject-arg "calc-misc" (&optional a p option))


;;; Physical constants
;;
;; CODATA values, held as Calc floats (see the Commentary for why these exist
;; rather than Calc's `c'/`G'/`h', and why the names are hyphenated).  Exact
;; by SI definition: c, h, g0.  Measured: the rest.

(defconst cmacs-calculator--c (math-read-number "299792458")
  "Speed of light in vacuum, m/s.  Exact by SI definition.")

(defconst cmacs-calculator--G (math-read-number "6.67430e-11")
  "Newtonian constant of gravitation, m^3 kg^-1 s^-2.")

(defconst cmacs-calculator--h (math-read-number "6.62607015e-34")
  "Planck constant, J s.  Exact by SI definition.")

(defconst cmacs-calculator--hbar (math-read-number "1.05457181764616e-34")
  "Reduced Planck constant h/2pi, J s.")

(defconst cmacs-calculator--g0 (math-read-number "9.80665")
  "Standard acceleration of gravity at Earth's surface, m/s^2.
Exact by definition; the true local value varies by about 0.5%.")

(defconst cmacs-calculator--R (math-read-number "8.31446261815324")
  "Molar gas constant, J mol^-1 K^-1.  Exact: it is Nav times Boltzmann's k.")

(defconst cmacs-calculator--ke (math-read-number "8.9875517862e9")
  "Coulomb constant 1/(4 pi eps0), N m^2 C^-2.
Note this is no longer exactly c^2 * 1e-7: the 2019 SI redefinition made
the vacuum permittivity a measured quantity, so the old exact value
8.9875517873681764e9 is out by a part in 1e10.")

(defconst cmacs-calculator--a0 (math-read-number "5.29177210544e-11")
  "Bohr radius, m.")

(defconst cmacs-calculator--e1 (math-read-number "-2.1798723611030e-18")
  "Ground-state energy of hydrogen, J.  Equal to -13.6056931230 eV.")


;;; Domain checks
;;
;; Modelled on `math-check-financial' in `calc-fin.el': signal through
;; `math-reject-arg' so Calc reports the call unevaluated rather than handing
;; back a number that is not one.  Symbolic arguments pass unchecked, so these
;; functions remain usable in CAS expressions.
;;
;; The `defmath' bodies below invoke these as ('cmacs-calculator--check-foo x),
;; with the quote, which is `defmath's escape for "call this plain Lisp
;; function".  The quote is load-bearing: `defmath' resolves a bare (foo x) by
;; testing `fboundp' *at macroexpansion time*, and when the file is being byte
;; compiled these defuns have not been evaluated yet, so it silently rewrites
;; the call to the non-existent `calcFunc-cmacs-calculator--check-foo'.  The
;; interpreted file works and the compiled one then dies with a void-function
;; error on every guarded call -- which is the only form that ships, since
;; Emacs prefers the .elc.

(defun cmacs-calculator--numeric (x)
  "Return X folded to a real number, or nil if it is not one.
Everything here goes through this rather than testing X with `math-realp'
directly.  Calc invokes an algebraic function while its arguments may still
be unevaluated -- `lorentz(pi/2)' arrives as the *form* `pi/2', not as
1.5708, because only the enclosing `evalv' substitutes `pi', and it does so
after the call.  A bare `math-realp' therefore sees a non-number, skips the
check, and lets the very input the check exists to catch straight through.
Folding first closes that hole while still returning nil for a genuinely
free variable, so symbolic algebra is unaffected."
  (let ((v (ignore-errors (math-evaluate-expr x))))
    (and v (math-realp v) v)))

(defun cmacs-calculator--check-beta (beta)
  "Reject BETA unless it is a usable velocity as a fraction of light speed.
Nothing material travels at or beyond c, and `lorentz' would otherwise
return a complex number that reads like an answer."
  (let ((v (cmacs-calculator--numeric beta)))
    (when (and v (not (math-lessp (math-abs v) 1)))
      (math-reject-arg beta "*Speed must be less than the speed of light"))))

(defun cmacs-calculator--check-refraction (n1 angle n2)
  "Reject a refraction that is really total internal reflection.
When N1 sin ANGLE exceeds N2 there is no refracted ray, and Snell's law
returns the arcsine of a number above 1 -- a complex angle."
  (let ((ratio (cmacs-calculator--numeric
                (math-div (math-mul n1 (calcFunc-sin angle)) n2))))
    (when (and ratio (math-lessp 1 (math-abs ratio)))
      (math-reject-arg angle "*Total internal reflection: no refracted ray"))))

(defun cmacs-calculator--check-critical (n1 n2)
  "Reject unless a critical angle exists between indices N1 and N2.
Total internal reflection needs the ray to start in the denser medium, so
N1 must exceed N2; otherwise arcsin(n2/n1) is the arcsine of a number above
1 and comes back complex."
  (let ((a (cmacs-calculator--numeric n1))
        (b (cmacs-calculator--numeric n2)))
    (when (and a b (not (math-lessp b a)))
      (math-reject-arg n2 "*Critical angle exists only when n1 > n2"))))


;;; Kinematics

(cmacs-calculator-defcalc kinvel (v0 accel secs)
  :category physics
  :title "Velocity after constant acceleration"
  :doc "Velocity after SECS of constant ACCEL starting from V0.  The first
kinematic equation, v = v0 + a t."
  :args ((v0 "Initial velocity, m/s")
         (accel "Constant acceleration, m/s^2")
         (secs "Elapsed time, s"))
  :returns "Velocity, m/s"
  :examples (("kinvel(0, 9.80665, 3)" . "29.41995"))
  (+ v0 (* accel secs)))

(cmacs-calculator-defcalc kinpos (x0 v0 accel secs)
  :category physics
  :title "Position under constant acceleration"
  :doc "Position after SECS of constant ACCEL, starting from X0 at velocity
V0.  The second kinematic equation, x = x0 + v0 t + a t^2 / 2."
  :args ((x0 "Initial position, m")
         (v0 "Initial velocity, m/s")
         (accel "Constant acceleration, m/s^2")
         (secs "Elapsed time, s"))
  :returns "Position, m"
  :examples (("kinpos(0, 0, 9.80665, 3)" . "44.129925"))
  (+ x0 (* v0 secs) (/ (* accel (^ secs 2)) 2)))

(cmacs-calculator-defcalc kinvelpos (v0 accel dist)
  :category physics
  :title "Velocity after a displacement"
  :doc "Speed reached after travelling DIST under constant ACCEL from V0.
The timeless kinematic equation v^2 = v0^2 + 2 a dx, solved for v -- use it
when the elapsed time is unknown.  Returns the positive root."
  :args ((v0 "Initial velocity, m/s")
         (accel "Constant acceleration, m/s^2")
         (dist "Displacement, m"))
  :returns "Speed, m/s"
  :examples (("kinvelpos(0, 9.80665, 10)" . "14.0047491945"))
  (sqrt (+ (^ v0 2) (* 2 accel dist))))


;;; Projectile motion
;;
;; Launch and landing at the same height, no air resistance.

(cmacs-calculator-defcalc projrange (v0 angle)
  :category physics
  :title "Projectile range"
  :doc "Horizontal distance travelled by a projectile launched at speed V0
and ANGLE above the horizontal, landing at its launch height.  Maximal at
ANGLE = pi/4."
  :args ((v0 "Launch speed, m/s")
         (angle "Launch angle above horizontal, radians"))
  :returns "Range, m"
  :examples (("projrange(20, pi/4)" . "40.7886485191"))
  (/ (* (^ v0 2) (sin (* 2 angle))) cmacs-calculator--g0))

(cmacs-calculator-defcalc projheight (v0 angle)
  :category physics
  :title "Projectile maximum height"
  :doc "Greatest height above the launch point reached by a projectile
launched at speed V0 and ANGLE above the horizontal."
  :args ((v0 "Launch speed, m/s")
         (angle "Launch angle above horizontal, radians"))
  :returns "Maximum height, m"
  :examples (("projheight(20, pi/4)" . "10.1971621298"))
  (/ (* (^ v0 2) (^ (sin angle) 2)) (* 2 cmacs-calculator--g0)))

(cmacs-calculator-defcalc projtime (v0 angle)
  :category physics
  :title "Projectile time of flight"
  :doc "Time a projectile launched at speed V0 and ANGLE above the horizontal
spends in the air before returning to its launch height."
  :args ((v0 "Launch speed, m/s")
         (angle "Launch angle above horizontal, radians"))
  :returns "Time of flight, s"
  :examples (("projtime(20, pi/4)" . "2.88419299633"))
  (/ (* 2 v0 (sin angle)) cmacs-calculator--g0))


;;; Newton's laws

(cmacs-calculator-defcalc force (mass accel)
  :category physics
  :title "Force"
  :doc "Newton's second law, F = m a."
  :args ((mass "Mass, kg") (accel "Acceleration, m/s^2"))
  :returns "Force, N"
  :examples (("force(10, 2)" . "20"))
  (* mass accel))

(cmacs-calculator-defcalc weight (mass)
  :category physics
  :title "Weight at Earth's surface"
  :doc "Gravitational force on MASS at Earth's surface, using standard
gravity.  For another body use `gravforce'."
  :args ((mass "Mass, kg"))
  :returns "Weight, N"
  :examples (("weight(70)" . "686.4655"))
  (* mass cmacs-calculator--g0))

(cmacs-calculator-defcalc friction (mu normal)
  :category physics
  :title "Friction force"
  :doc "Friction force from coefficient MU and NORMAL force.  MU is the
static coefficient for the maximum force before sliding starts, or the
kinetic coefficient for the force while sliding."
  :args ((mu "Coefficient of friction, dimensionless")
         (normal "Normal force, N"))
  :returns "Friction force, N"
  :examples (("friction(0.3, 686.4655)" . "205.93965"))
  (* mu normal))


;;; Work, energy and power

(cmacs-calculator-defcalc work (fmag dist angle)
  :category physics
  :title "Work done by a force"
  :doc "Work done by a constant force of magnitude FMAG over DIST, where
ANGLE is between the force and the displacement.  Zero at ANGLE = pi/2, and
negative beyond it."
  :args ((fmag "Force magnitude, N")
         (dist "Displacement, m")
         (angle "Angle between force and displacement, radians"))
  :returns "Work, J"
  :examples (("work(20, 5, 0)" . "100"))
  (* fmag dist (cos angle)))

(cmacs-calculator-defcalc power (energy secs)
  :category physics
  :title "Average power"
  :doc "Average rate of energy transfer, ENERGY over SECS."
  :args ((energy "Energy transferred, J") (secs "Elapsed time, s"))
  :returns "Power, W"
  :examples (("power(1000, 4)" . "250"))
  (/ energy secs))

(cmacs-calculator-defcalc kinetic (mass vel)
  :category physics
  :title "Kinetic energy"
  :doc "Classical kinetic energy, m v^2 / 2.  Accurate below roughly 0.1c;
above that use `relke'."
  :args ((mass "Mass, kg") (vel "Speed, m/s"))
  :returns "Kinetic energy, J"
  :examples (("kinetic(2, 10)" . "100"))
  (/ (* mass (^ vel 2)) 2))

(cmacs-calculator-defcalc potential (mass height)
  :category physics
  :title "Gravitational potential energy"
  :doc "Potential energy of MASS raised to HEIGHT near Earth's surface,
m g h.  Valid while HEIGHT is small against Earth's radius."
  :args ((mass "Mass, kg") (height "Height above the reference level, m"))
  :returns "Potential energy, J"
  :examples (("potential(2, 10)" . "196.133"))
  (* mass cmacs-calculator--g0 height))

(cmacs-calculator-defcalc springpe (springk disp)
  :category physics
  :title "Elastic potential energy"
  :doc "Energy stored in a spring of stiffness SPRINGK displaced by DISP
from equilibrium, k x^2 / 2."
  :args ((springk "Spring constant, N/m")
         (disp "Displacement from equilibrium, m"))
  :returns "Stored energy, J"
  :examples (("springpe(200, 0.1)" . "1."))
  (/ (* springk (^ disp 2)) 2))


;;; Momentum

(cmacs-calculator-defcalc momentum (mass vel)
  :category physics
  :title "Momentum"
  :doc "Classical momentum, p = m v.  Above roughly 0.1c use `relmomentum'."
  :args ((mass "Mass, kg") (vel "Velocity, m/s"))
  :returns "Momentum, kg m/s"
  :examples (("momentum(2, 10)" . "20"))
  (* mass vel))

(cmacs-calculator-defcalc impulse (fmag secs)
  :category physics
  :title "Impulse"
  :doc "Impulse delivered by a constant force FMAG acting for SECS, equal to
the change in momentum it produces."
  :args ((fmag "Force, N") (secs "Duration, s"))
  :returns "Impulse, N s (= kg m/s)"
  :examples (("impulse(50, 0.2)" . "10."))
  (* fmag secs))

(cmacs-calculator-defcalc elasticv1 (m1 v1 m2 v2)
  :category physics
  :title "Elastic collision -- final velocity of the first body"
  :doc "Velocity of the first body after a one-dimensional elastic
collision, conserving both momentum and kinetic energy.  Velocities are
signed: negative means motion in the opposite direction.  Equal masses swap
velocities, which is the standard check."
  :args ((m1 "Mass of the first body, kg")
         (v1 "Initial velocity of the first body, m/s")
         (m2 "Mass of the second body, kg")
         (v2 "Initial velocity of the second body, m/s"))
  :returns "Final velocity of the first body, m/s"
  :examples (("elasticv1(2, 5, 3, -2)" . "-3.4"))
  (/ (+ (* (- m1 m2) v1) (* 2 m2 v2)) (+ m1 m2)))

(cmacs-calculator-defcalc elasticv2 (m1 v1 m2 v2)
  :category physics
  :title "Elastic collision -- final velocity of the second body"
  :doc "Velocity of the second body after a one-dimensional elastic
collision.  Arguments are as in `elasticv1'."
  :args ((m1 "Mass of the first body, kg")
         (v1 "Initial velocity of the first body, m/s")
         (m2 "Mass of the second body, kg")
         (v2 "Initial velocity of the second body, m/s"))
  :returns "Final velocity of the second body, m/s"
  :examples (("elasticv2(2, 5, 3, -2)" . "3.6"))
  (/ (+ (* (- m2 m1) v2) (* 2 m1 v1)) (+ m1 m2)))

(cmacs-calculator-defcalc inelasticv (m1 v1 m2 v2)
  :category physics
  :title "Perfectly inelastic collision -- common final velocity"
  :doc "Velocity of the combined body after a one-dimensional perfectly
inelastic collision, in which the two bodies stick together.  Momentum is
conserved; kinetic energy is not."
  :args ((m1 "Mass of the first body, kg")
         (v1 "Initial velocity of the first body, m/s")
         (m2 "Mass of the second body, kg")
         (v2 "Initial velocity of the second body, m/s"))
  :returns "Common final velocity, m/s"
  :examples (("inelasticv(2, 5, 3, -2)" . "0.8"))
  (/ (+ (* m1 v1) (* m2 v2)) (+ m1 m2)))


;;; Circular and rotational motion

(cmacs-calculator-defcalc centripaccel (vel radius)
  :category physics
  :title "Centripetal acceleration"
  :doc "Acceleration toward the centre for uniform circular motion at speed
VEL on a circle of RADIUS."
  :args ((vel "Tangential speed, m/s") (radius "Radius of the circle, m"))
  :returns "Centripetal acceleration, m/s^2"
  :examples (("centripaccel(10, 4)" . "25"))
  (/ (^ vel 2) radius))

(cmacs-calculator-defcalc centripforce (mass vel radius)
  :category physics
  :title "Centripetal force"
  :doc "Net inward force needed to keep MASS moving at VEL on a circle of
RADIUS."
  :args ((mass "Mass, kg") (vel "Tangential speed, m/s")
         (radius "Radius of the circle, m"))
  :returns "Centripetal force, N"
  :examples (("centripforce(2, 10, 4)" . "50"))
  (/ (* mass (^ vel 2)) radius))

(cmacs-calculator-defcalc angvel (freq)
  :category physics
  :title "Angular velocity from frequency"
  :doc "Angular velocity of rotation at FREQ revolutions per second,
omega = 2 pi f."
  :args ((freq "Rotation frequency, Hz"))
  :returns "Angular velocity, rad/s"
  :examples (("angvel(2)" . "12.5663706144"))
  (* 2 pi freq))

(cmacs-calculator-defcalc torque (fmag radius angle)
  :category physics
  :title "Torque"
  :doc "Torque from a force of magnitude FMAG applied at RADIUS from the
axis, where ANGLE is between the lever arm and the force.  Maximal at
ANGLE = pi/2, zero for a force pointing along the arm."
  :args ((fmag "Force magnitude, N")
         (radius "Distance from the axis, m")
         (angle "Angle between lever arm and force, radians"))
  :returns "Torque, N m"
  :examples (("torque(50, 0.3, pi/2)" . "15."))
  (* radius fmag (sin angle)))

(cmacs-calculator-defcalc inertiadisk (mass radius)
  :category physics
  :title "Moment of inertia -- solid disk or cylinder"
  :doc "Moment of inertia of a uniform solid disk or cylinder about its
symmetry axis, m r^2 / 2."
  :args ((mass "Mass, kg") (radius "Radius, m"))
  :returns "Moment of inertia, kg m^2"
  :examples (("inertiadisk(2, 0.5)" . "0.25"))
  (/ (* mass (^ radius 2)) 2))

(cmacs-calculator-defcalc inertiahoop (mass radius)
  :category physics
  :title "Moment of inertia -- hoop or thin ring"
  :doc "Moment of inertia of a hoop or thin-walled cylinder about its
symmetry axis, m r^2.  All the mass sits at the radius, so this is the
largest inertia any shape of this radius can have."
  :args ((mass "Mass, kg") (radius "Radius, m"))
  :returns "Moment of inertia, kg m^2"
  :examples (("inertiahoop(2, 0.5)" . "0.5"))
  (* mass (^ radius 2)))

(cmacs-calculator-defcalc inertiasphere (mass radius)
  :category physics
  :title "Moment of inertia -- solid sphere"
  :doc "Moment of inertia of a uniform solid sphere about a diameter,
2 m r^2 / 5."
  :args ((mass "Mass, kg") (radius "Radius, m"))
  :returns "Moment of inertia, kg m^2"
  :examples (("inertiasphere(2, 0.5)" . "0.2"))
  (/ (* 2 mass (^ radius 2)) 5))

(cmacs-calculator-defcalc inertiashell (mass radius)
  :category physics
  :title "Moment of inertia -- hollow sphere"
  :doc "Moment of inertia of a thin spherical shell about a diameter,
2 m r^2 / 3."
  :args ((mass "Mass, kg") (radius "Radius, m"))
  :returns "Moment of inertia, kg m^2"
  :examples (("inertiashell(2, 0.5)" . "0.333333333333"))
  (/ (* 2 mass (^ radius 2)) 3))

(cmacs-calculator-defcalc inertiarod (mass len)
  :category physics
  :title "Moment of inertia -- rod about its centre"
  :doc "Moment of inertia of a uniform thin rod of length LEN about an axis
through its centre, perpendicular to the rod: m L^2 / 12."
  :args ((mass "Mass, kg") (len "Length, m"))
  :returns "Moment of inertia, kg m^2"
  :examples (("inertiarod(2, 1)" . "0.166666666667"))
  (/ (* mass (^ len 2)) 12))

(cmacs-calculator-defcalc inertiarodend (mass len)
  :category physics
  :title "Moment of inertia -- rod about one end"
  :doc "Moment of inertia of a uniform thin rod of length LEN about an axis
through one end, perpendicular to the rod: m L^2 / 3.  Four times
`inertiarod', as the parallel-axis theorem requires."
  :args ((mass "Mass, kg") (len "Length, m"))
  :returns "Moment of inertia, kg m^2"
  :examples (("inertiarodend(2, 1)" . "0.666666666667"))
  (/ (* mass (^ len 2)) 3))

(cmacs-calculator-defcalc rotke (inertia omega)
  :category physics
  :title "Rotational kinetic energy"
  :doc "Kinetic energy of a body with moment of INERTIA spinning at angular
velocity OMEGA, I w^2 / 2.  The rotational counterpart of `kinetic'."
  :args ((inertia "Moment of inertia, kg m^2")
         (omega "Angular velocity, rad/s"))
  :returns "Rotational kinetic energy, J"
  :examples (("rotke(0.25, 12.5663706144)" . "19.7392088023"))
  (/ (* inertia (^ omega 2)) 2))


;;; Gravitation

(cmacs-calculator-defcalc gravforce (m1 m2 dist)
  :category physics
  :title "Newton's law of universal gravitation"
  :doc "Attractive force between point masses M1 and M2 separated by DIST."
  :args ((m1 "First mass, kg") (m2 "Second mass, kg")
         (dist "Separation of the centres, m"))
  :returns "Force, N"
  :examples (("gravforce(5.972e24, 70, 6.371e6)" . "687.398139836"))
  (/ (* cmacs-calculator--G m1 m2) (^ dist 2)))

(cmacs-calculator-defcalc orbitalvel (mass radius)
  :category physics
  :title "Circular orbital velocity"
  :doc "Speed needed for a circular orbit of RADIUS about a body of MASS,
sqrt(G M / r).  RADIUS is measured from the centre, not the surface."
  :args ((mass "Mass of the central body, kg")
         (radius "Orbital radius from the centre, m"))
  :returns "Orbital speed, m/s"
  :examples (("orbitalvel(5.972e24, 6.771e6)" . "7672.49041328"))
  (sqrt (/ (* cmacs-calculator--G mass) radius)))

(cmacs-calculator-defcalc escapevel (mass radius)
  :category physics
  :title "Escape velocity"
  :doc "Speed needed to escape a body of MASS from RADIUS with no further
propulsion, sqrt(2 G M / r).  Exactly sqrt(2) times `orbitalvel'."
  :args ((mass "Mass of the body, kg")
         (radius "Distance from the centre, m"))
  :returns "Escape speed, m/s"
  :examples (("escapevel(5.972e24, 6.371e6)" . "11185.9778919"))
  (sqrt (/ (* 2 cmacs-calculator--G mass) radius)))

(cmacs-calculator-defcalc visviva (mass radius semimajor)
  :category physics
  :title "Vis-viva equation"
  :doc "Orbital speed at RADIUS on any conic orbit of semi-major axis
SEMIMAJOR about a body of MASS: sqrt(G M (2/r - 1/a)).  Reduces to
`orbitalvel' when RADIUS equals SEMIMAJOR (a circle), and to `escapevel' as
SEMIMAJOR tends to infinity (a parabola)."
  :args ((mass "Mass of the central body, kg")
         (radius "Current distance from the centre, m")
         (semimajor "Semi-major axis of the orbit, m"))
  :returns "Orbital speed, m/s"
  :examples (("visviva(1.989e30, 1.471e11, 1.496e11)" . "30290.9383647"))
  (sqrt (* cmacs-calculator--G mass (- (/ 2 radius) (/ 1 semimajor)))))

(cmacs-calculator-defcalc orbitperiod (mass semimajor)
  :category physics
  :title "Orbital period (Kepler's third law)"
  :doc "Time for one orbit of semi-major axis SEMIMAJOR about a body of
MASS, 2 pi sqrt(a^3 / (G M)).  Kepler's third law solved for the period;
note it does not depend on the orbiting body's own mass."
  :args ((mass "Mass of the central body, kg")
         (semimajor "Semi-major axis, m"))
  :returns "Orbital period, s"
  :examples (("orbitperiod(1.989e30, 1.496e11)" . "31554187.7477"))
  (* 2 pi (sqrt (/ (^ semimajor 3) (* cmacs-calculator--G mass)))))

(cmacs-calculator-defcalc kepler3 (semimajor period)
  :category physics
  :title "Central mass from Kepler's third law"
  :doc "Mass of the central body implied by an orbit of semi-major axis
SEMIMAJOR and PERIOD: 4 pi^2 a^3 / (G T^2).  Kepler's third law solved the
other way round from `orbitperiod' -- this is how the mass of a star or
planet is measured from watching something orbit it."
  :args ((semimajor "Semi-major axis, m") (period "Orbital period, s"))
  :returns "Mass of the central body, kg"
  :examples (("kepler3(1.496e11, 31557600)" . "1.98856989105e30"))
  (/ (* 4 (^ pi 2) (^ semimajor 3))
     (* cmacs-calculator--G (^ period 2))))


;;; Oscillation and waves

(cmacs-calculator-defcalc pendulum (len)
  :category physics
  :title "Simple pendulum period"
  :doc "Period of a simple pendulum of length LEN at Earth's surface,
2 pi sqrt(L/g).  The small-angle approximation: it does not depend on the
bob's mass, and holds to about 1% below roughly 20 degrees of swing."
  :args ((len "Pendulum length, m"))
  :returns "Period, s"
  :examples (("pendulum(1)" . "2.00640929259"))
  (* 2 pi (sqrt (/ len cmacs-calculator--g0))))

(cmacs-calculator-defcalc springperiod (mass springk)
  :category physics
  :title "Mass-spring period"
  :doc "Period of a mass on a spring of stiffness SPRINGK,
2 pi sqrt(m/k).  Unlike `pendulum', this is independent of gravity."
  :args ((mass "Mass, kg") (springk "Spring constant, N/m"))
  :returns "Period, s"
  :examples (("springperiod(0.5, 200)" . "0.314159265359"))
  (* 2 pi (sqrt (/ mass springk))))

(cmacs-calculator-defcalc wavespeed (freq wavelen)
  :category physics
  :title "Wave speed"
  :doc "Propagation speed of a wave, v = f lambda."
  :args ((freq "Frequency, Hz") (wavelen "Wavelength, m"))
  :returns "Wave speed, m/s"
  :examples (("wavespeed(440, 0.78)" . "343.2"))
  (* freq wavelen))

(cmacs-calculator-defcalc dopplersound (freq vsound vobs vsrc)
  :category physics
  :title "Doppler shift for sound"
  :doc "Frequency heard by a moving observer from a moving source,
f (v + vo) / (v - vs).

Signs follow the standard convention: VOBS is positive when the observer
moves *toward* the source, VSRC is positive when the source moves *toward*
the observer, so approaching raises the pitch either way.  These are speeds
through the medium, which is why the two enter asymmetrically -- unlike the
relativistic case, see `reldoppler'."
  :args ((freq "Emitted frequency, Hz")
         (vsound "Speed of sound in the medium, m/s, about 343 in air")
         (vobs "Observer speed toward the source, m/s")
         (vsrc "Source speed toward the observer, m/s"))
  :returns "Observed frequency, Hz"
  :examples (("dopplersound(440, 343, 0, 30)" . "482.172523962"))
  (/ (* freq (+ vsound vobs)) (- vsound vsrc)))


;;; Thermodynamics

(cmacs-calculator-defcalc idealgasp (moles temp volume)
  :category physics
  :title "Ideal gas pressure"
  :doc "Pressure of an ideal gas, from PV = nRT solved for P."
  :args ((moles "Amount of substance, mol")
         (temp "Absolute temperature, K")
         (volume "Volume, m^3"))
  :returns "Pressure, Pa"
  :examples (("idealgasp(1, 273.15, 0.0224140)" . "101324.862325"))
  (/ (* moles cmacs-calculator--R temp) volume))

(cmacs-calculator-defcalc idealgasv (moles temp pressure)
  :category physics
  :title "Ideal gas volume"
  :doc "Volume of an ideal gas, from PV = nRT solved for V.  One mole at
standard temperature and pressure occupies about 0.0224 m^3."
  :args ((moles "Amount of substance, mol")
         (temp "Absolute temperature, K")
         (pressure "Pressure, Pa"))
  :returns "Volume, m^3"
  :examples (("idealgasv(1, 273.15, 101325)" . "0.022413969545"))
  (/ (* moles cmacs-calculator--R temp) pressure))

(cmacs-calculator-defcalc heat (mass spheat dtemp)
  :category physics
  :title "Heat transferred"
  :doc "Heat needed to change the temperature of MASS by DTEMP, Q = m c dT.
SPHEAT is about 4186 for water and 897 for aluminium.  This covers heating
only: a phase change absorbs heat at constant temperature and is not
modelled here."
  :args ((mass "Mass, kg")
         (spheat "Specific heat capacity, J kg^-1 K^-1")
         (dtemp "Temperature change, K"))
  :returns "Heat, J"
  :examples (("heat(2, 4186, 30)" . "251160"))
  (* mass spheat dtemp))

(cmacs-calculator-defcalc carnot (tcold thot)
  :category physics
  :title "Carnot efficiency"
  :doc "Maximum efficiency of any heat engine working between reservoirs at
THOT and TCOLD, 1 - Tc/Th.  Temperatures are absolute -- using Celsius here
is the classic error.  No real engine beats this."
  :args ((tcold "Cold reservoir temperature, K")
         (thot "Hot reservoir temperature, K"))
  :returns "Efficiency as a fraction, between 0 and 1"
  :examples (("carnot(300, 500)" . "0.4"))
  (- 1 (/ tcold thot)))

(cmacs-calculator-defcalc thermexp (len alpha dtemp)
  :category physics
  :title "Linear thermal expansion"
  :doc "Change in length of an object of length LEN heated by DTEMP,
dL = L alpha dT.  ALPHA is about 1.2e-5 for steel and 2.3e-5 for aluminium.
Returns the change, not the new length."
  :args ((len "Original length, m")
         (alpha "Coefficient of linear expansion, 1/K")
         (dtemp "Temperature change, K"))
  :returns "Change in length, m"
  :examples (("thermexp(10, 1.2e-5, 50)" . "6e-3"))
  (* len alpha dtemp))


;;; Electromagnetism

(cmacs-calculator-defcalc coulomb (q1 q2 dist)
  :category physics
  :title "Coulomb's law"
  :doc "Electrostatic force between point charges Q1 and Q2 separated by
DIST.  Positive means repulsion, negative attraction, so the sign of the
charges matters."
  :args ((q1 "First charge, C") (q2 "Second charge, C")
         (dist "Separation, m"))
  :returns "Force, N (positive = repulsive)"
  :examples (("coulomb(1e-6, 1e-6, 0.1)" . "0.89875517862"))
  (/ (* cmacs-calculator--ke q1 q2) (^ dist 2)))

(cmacs-calculator-defcalc efield (charge dist)
  :category physics
  :title "Electric field of a point charge"
  :doc "Field strength at DIST from a point CHARGE, k q / r^2."
  :args ((charge "Source charge, C") (dist "Distance from the charge, m"))
  :returns "Electric field, V/m"
  :examples (("efield(1e-6, 0.1)" . "898755.17862"))
  (/ (* cmacs-calculator--ke charge) (^ dist 2)))

(cmacs-calculator-defcalc epotential (charge dist)
  :category physics
  :title "Electric potential of a point charge"
  :doc "Potential at DIST from a point CHARGE, k q / r, taking the potential
to be zero infinitely far away."
  :args ((charge "Source charge, C") (dist "Distance from the charge, m"))
  :returns "Electric potential, V"
  :examples (("epotential(1e-6, 0.1)" . "89875.517862"))
  (/ (* cmacs-calculator--ke charge) dist))

(cmacs-calculator-defcalc ohmv (current resist)
  :category physics
  :title "Ohm's law -- voltage"
  :doc "Voltage across a resistor, V = I R."
  :args ((current "Current, A") (resist "Resistance, ohm"))
  :returns "Voltage, V"
  :examples (("ohmv(0.5, 220)" . "110."))
  (* current resist))

(cmacs-calculator-defcalc ohmi (volts resist)
  :category physics
  :title "Ohm's law -- current"
  :doc "Current through a resistor, I = V / R."
  :args ((volts "Voltage, V") (resist "Resistance, ohm"))
  :returns "Current, A"
  :examples (("ohmi(110, 220)" . "0.5"))
  (/ volts resist))

(cmacs-calculator-defcalc ohmr (volts current)
  :category physics
  :title "Ohm's law -- resistance"
  :doc "Resistance implied by VOLTS and CURRENT, R = V / I."
  :args ((volts "Voltage, V") (current "Current, A"))
  :returns "Resistance, ohm"
  :examples (("ohmr(110, 0.5)" . "220."))
  (/ volts current))

(cmacs-calculator-defcalc epower (volts current)
  :category physics
  :title "Electrical power"
  :doc "Power dissipated, P = V I.  Combine with `ohmv' or `ohmi' for the
other two forms: epower(ohmv(i, r), i) is I^2 R."
  :args ((volts "Voltage, V") (current "Current, A"))
  :returns "Power, W"
  :examples (("epower(110, 0.5)" . "55."))
  (* volts current))

(cmacs-calculator-defcalc resseries (r1 r2)
  :category physics
  :title "Resistors in series"
  :doc "Resistance of R1 and R2 in series, R1 + R2.  Nest for more than
two: resseries(resseries(100, 220), 330)."
  :args ((r1 "First resistance, ohm") (r2 "Second resistance, ohm"))
  :returns "Total resistance, ohm"
  :examples (("resseries(100, 220)" . "320"))
  (+ r1 r2))

(cmacs-calculator-defcalc respar (r1 r2)
  :category physics
  :title "Resistors in parallel"
  :doc "Resistance of R1 and R2 in parallel, R1 R2 / (R1 + R2).  Always
smaller than either.  Nest for more than two:
respar(respar(100, 220), 330)."
  :args ((r1 "First resistance, ohm") (r2 "Second resistance, ohm"))
  :returns "Total resistance, ohm"
  :examples (("respar(100, 220)" . "68.75"))
  (/ (* r1 r2) (+ r1 r2)))

(cmacs-calculator-defcalc capacitance (charge volts)
  :category physics
  :title "Capacitance"
  :doc "Capacitance holding CHARGE at VOLTS, C = Q / V."
  :args ((charge "Stored charge, C") (volts "Voltage across the plates, V"))
  :returns "Capacitance, F"
  :examples (("capacitance(1e-6, 5)" . "2e-7"))
  (/ charge volts))

(cmacs-calculator-defcalc capenergy (cap volts)
  :category physics
  :title "Energy stored in a capacitor"
  :doc "Energy stored at VOLTS across capacitance CAP, C V^2 / 2."
  :args ((cap "Capacitance, F") (volts "Voltage, V"))
  :returns "Stored energy, J"
  :examples (("capenergy(1e-6, 12)" . "7.2e-5"))
  (/ (* cap (^ volts 2)) 2))

(cmacs-calculator-defcalc magforce (charge vel bfield angle)
  :category physics
  :title "Magnetic force on a moving charge"
  :doc "Lorentz magnetic force, q v B sin(theta), where ANGLE is between the
velocity and the field.  Zero when the charge moves along the field, maximal
across it.  This force is always perpendicular to the motion, so it does no
work and only bends the path."
  :args ((charge "Charge, C") (vel "Speed, m/s")
         (bfield "Magnetic flux density, T")
         (angle "Angle between velocity and field, radians"))
  :returns "Force, N"
  :examples (("magforce(1.602176634e-19, 1e6, 0.5, pi/2)" . "8.01088317e-14"))
  (* charge vel bfield (sin angle)))


;;; Optics

(cmacs-calculator-defcalc snell (n1 angle n2)
  :category physics
  :title "Snell's law -- angle of refraction"
  :doc "Angle of the refracted ray crossing from a medium of index N1 into
one of index N2, arcsin(n1 sin(theta1) / n2).  Angles are from the normal,
in radians.

Rejected when the ray would be totally internally reflected -- going from
dense to rare beyond the critical angle, where no refracted ray exists.  See
`criticalangle'."
  :args ((n1 "Refractive index of the incident medium, e.g. 1 for vacuum")
         (angle "Angle of incidence from the normal, radians")
         (n2 "Refractive index of the transmitting medium, e.g. 1.5 for glass"))
  :returns "Angle of refraction from the normal, radians"
  :examples (("snell(1, pi/6, 1.5)" . "0.339836909454"))
  (progn
    ('cmacs-calculator--check-refraction n1 angle n2)
    (arcsin (/ (* n1 (sin angle)) n2))))

(cmacs-calculator-defcalc criticalangle (n1 n2)
  :category physics
  :title "Critical angle for total internal reflection"
  :doc "Angle of incidence beyond which light travelling from index N1 into
index N2 is totally internally reflected, arcsin(n2/n1).  Exists only when
N1 exceeds N2; the call is rejected otherwise, since a ray leaving a rarer
medium never runs out of refraction angles."
  :args ((n1 "Refractive index of the dense incident medium")
         (n2 "Refractive index of the rarer medium"))
  :returns "Critical angle from the normal, radians"
  :examples (("criticalangle(1.33, 1)" . "0.850908514478"))
  (progn
    ('cmacs-calculator--check-critical n1 n2)
    (arcsin (/ n2 n1))))

(cmacs-calculator-defcalc lensdi (focal dobj)
  :category physics
  :title "Thin lens -- image distance"
  :doc "Image distance for an object at DOBJ from a thin lens of focal
length FOCAL: from 1/f = 1/do + 1/di, so di = f do / (do - f).

Sign convention: FOCAL is positive for a converging lens and negative for a
diverging one; a positive result is a real image on the far side, a negative
one a virtual image on the object's side.  An object at the focal point
gives `uinf' -- the rays leave parallel and no image forms."
  :args ((focal "Focal length, m") (dobj "Object distance from the lens, m"))
  :returns "Image distance, m"
  :examples (("lensdi(0.1, 0.3)" . "0.15"))
  (/ (* focal dobj) (- dobj focal)))

(cmacs-calculator-defcalc lensmag (dobj dimg)
  :category physics
  :title "Thin lens -- magnification"
  :doc "Magnification of a thin lens, -di/do.  Negative means the image is
inverted; a magnitude below 1 means it is smaller than the object.  Pair
with `lensdi': lensmag(0.3, lensdi(0.1, 0.3))."
  :args ((dobj "Object distance, m") (dimg "Image distance, m"))
  :returns "Magnification (negative = inverted)"
  :examples (("lensmag(0.3, 0.15)" . "-0.5"))
  (- (/ dimg dobj)))


;;; Quantum

(cmacs-calculator-defcalc photonenergy (freq)
  :category physics
  :title "Photon energy from frequency"
  :doc "Energy of a photon of frequency FREQ, E = h f."
  :args ((freq "Frequency, Hz"))
  :returns "Photon energy, J"
  :examples (("photonenergy(6e14)" . "3.97564209e-19"))
  (* cmacs-calculator--h freq))

(cmacs-calculator-defcalc photonenergywl (wavelen)
  :category physics
  :title "Photon energy from wavelength"
  :doc "Energy of a photon of wavelength WAVELEN, E = h c / lambda.  Visible
light runs from about 400 nm (violet) to 700 nm (red); divide the result by
1.602176634e-19 for electronvolts."
  :args ((wavelen "Wavelength, m"))
  :returns "Photon energy, J"
  :examples (("photonenergywl(500e-9)" . "3.9728917143e-19"))
  (/ (* cmacs-calculator--h cmacs-calculator--c) wavelen))

(cmacs-calculator-defcalc debroglie (mass vel)
  :category physics
  :title "de Broglie wavelength"
  :doc "Matter wavelength of a particle, lambda = h / (m v).  Non-relativistic;
above roughly 0.1c the momentum needs `relmomentum' instead.  The wavelength
of anything macroscopic is far too small to observe, which is why the
quantum world looks classical."
  :args ((mass "Mass, kg") (vel "Speed, m/s"))
  :returns "Wavelength, m"
  :examples (("debroglie(9.1093837139e-31, 1e6)" . "7.27389509335e-10"))
  (/ cmacs-calculator--h (* mass vel)))

(cmacs-calculator-defcalc heisenberg (dx)
  :category physics
  :title "Heisenberg uncertainty -- minimum momentum spread"
  :doc "Smallest momentum uncertainty compatible with a position uncertainty
of DX, from dx dp >= hbar/2 taken at equality."
  :args ((dx "Position uncertainty, m"))
  :returns "Minimum momentum uncertainty, kg m/s"
  :examples (("heisenberg(1e-10)" . "5.27285908825e-25"))
  (/ cmacs-calculator--hbar (* 2 dx)))

(cmacs-calculator-defcalc bohrradius (level)
  :category physics
  :title "Bohr model -- orbit radius"
  :doc "Radius of the LEVEL-th orbit of hydrogen in the Bohr model,
n^2 a0.  LEVEL is the principal quantum number, 1 for the ground state."
  :args ((level "Principal quantum number n, a positive integer"))
  :returns "Orbit radius, m"
  :examples (("bohrradius(1)" . "5.29177210544e-11")
             ("bohrradius(2)" . "2.11670884218e-10"))
  (* (^ level 2) cmacs-calculator--a0))

(cmacs-calculator-defcalc bohrenergy (level)
  :category physics
  :title "Bohr model -- energy level"
  :doc "Energy of the LEVEL-th state of hydrogen, E1 / n^2, where E1 is
-2.1798723611030e-18 J (-13.6056931230 eV).  Negative because the electron
is bound; divide by 1.602176634e-19 for electronvolts.  The energy of a
photon emitted in a transition is the difference of two of these."
  :args ((level "Principal quantum number n, a positive integer"))
  :returns "Energy, J (negative)"
  :examples (("bohrenergy(1)" . "-2.1798723611e-18")
             ("bohrenergy(2)" . "-5.44968090275e-19"))
  (/ cmacs-calculator--e1 (^ level 2)))

(cmacs-calculator-defcalc photoelectric (freq workfn)
  :category physics
  :title "Photoelectric effect -- maximum electron energy"
  :doc "Maximum kinetic energy of an electron ejected by light of frequency
FREQ from a surface of work function WORKFN: h f - phi.

A negative result means FREQ is below the threshold and no electron is
emitted at all -- the magnitude is how far short the photon falls.  Einstein's
point was that this depends on frequency, not intensity: brighter light below
the threshold still ejects nothing.  See `photothreshold'.  Work functions are
usually quoted in eV; multiply by 1.602176634e-19 for WORKFN."
  :args ((freq "Frequency of the incident light, Hz")
         (workfn "Work function of the surface, J"))
  :returns "Maximum electron kinetic energy, J (negative = below threshold)"
  :examples (("photoelectric(1e15, 7.22e-19)" . "-5.9392985e-20")
             ("photoelectric(1.2e15, 7.22e-19)" . "7.3128418e-20"))
  (- (* cmacs-calculator--h freq) workfn))

(cmacs-calculator-defcalc photothreshold (workfn)
  :category physics
  :title "Photoelectric threshold frequency"
  :doc "Lowest frequency that ejects an electron from a surface of work
function WORKFN, phi / h.  Below this `photoelectric' goes negative."
  :args ((workfn "Work function of the surface, J"))
  :returns "Threshold frequency, Hz"
  :examples (("photothreshold(7.22e-19)" . "1.0896353097e15"))
  (/ workfn cmacs-calculator--h))


;;; Special relativity
;;
;; Speeds are BETA, a fraction of c -- see the Commentary.

(cmacs-calculator-defcalc lorentz (beta)
  :category relativity
  :title "Lorentz factor"
  :doc "The Lorentz factor gamma = 1 / sqrt(1 - beta^2), where BETA is speed
as a fraction of the speed of light: pass 0.9 for 0.9c.  Gamma is 1 at rest,
about 1.005 at 0.1c, and diverges as BETA approaches 1 -- which is why no
mass reaches c.

Rejected for |BETA| at or above 1; undefended the formula would return a
complex number."
  :args ((beta "Speed as a fraction of c, |beta| < 1"))
  :returns "Lorentz factor gamma, always at least 1"
  :examples (("lorentz(0.9)" . "2.29415733871")
             ("lorentz(0.99)" . "7.08881205007"))
  (progn
    ('cmacs-calculator--check-beta beta)
    (/ 1 (sqrt (- 1 (^ beta 2))))))

(cmacs-calculator-defcalc timedilation (propertime beta)
  :category relativity
  :title "Time dilation"
  :doc "Time elapsed in the observer's frame while PROPERTIME passes on a
clock moving at BETA, gamma t0.  The moving clock runs slow, so the result
is always the larger."
  :args ((propertime "Time on the moving clock, s")
         (beta "Speed as a fraction of c, |beta| < 1"))
  :returns "Time in the observer's frame, s"
  :examples (("timedilation(1, 0.9)" . "2.29415733871"))
  (* propertime (lorentz beta)))

(cmacs-calculator-defcalc lengthcontraction (properlen beta)
  :category relativity
  :title "Length contraction"
  :doc "Length an observer measures for an object of rest length PROPERLEN
moving at BETA, L0 / gamma.  Contraction is along the direction of motion
only, and the result is always the smaller."
  :args ((properlen "Rest length of the object, m")
         (beta "Speed as a fraction of c, |beta| < 1"))
  :returns "Contracted length, m"
  :examples (("lengthcontraction(1, 0.9)" . "0.435889894353"))
  (/ properlen (lorentz beta)))

(cmacs-calculator-defcalc veladd (beta1 beta2)
  :category relativity
  :title "Relativistic velocity addition"
  :doc "Composition of two collinear velocities, (b1 + b2) / (1 + b1 b2),
with both given and returned as fractions of c.  The result never reaches 1
however close the inputs get -- veladd(0.9, 0.9) is 0.994, not 1.8 -- and
veladd(1, x) would be exactly 1, which is light speed being the same in
every frame."
  :args ((beta1 "First speed as a fraction of c, |beta| < 1")
         (beta2 "Second speed as a fraction of c, |beta| < 1"))
  :returns "Combined speed as a fraction of c"
  :examples (("veladd(0.9, 0.9)" . "0.994475138122")
             ("veladd(0.5, 0.5)" . "0.8"))
  (progn
    ('cmacs-calculator--check-beta beta1)
    ('cmacs-calculator--check-beta beta2)
    (/ (+ beta1 beta2) (+ 1 (* beta1 beta2)))))

(cmacs-calculator-defcalc relmomentum (mass beta)
  :category relativity
  :title "Relativistic momentum"
  :doc "Momentum of MASS moving at BETA, gamma m v.  MASS is the rest mass
in kg and BETA a fraction of c, but the result is in SI units, kg m/s.
Exceeds the classical `momentum' by the factor gamma."
  :args ((mass "Rest mass, kg")
         (beta "Speed as a fraction of c, |beta| < 1"))
  :returns "Momentum, kg m/s"
  :examples (("relmomentum(1, 0.9)" . "618993960.85"))
  (* (lorentz beta) mass beta cmacs-calculator--c))

(cmacs-calculator-defcalc relke (mass beta)
  :category relativity
  :title "Relativistic kinetic energy"
  :doc "Kinetic energy of MASS moving at BETA, (gamma - 1) m c^2.  MASS is
the rest mass in kg; the result is in joules.  Reduces to `kinetic' at low
speed and diverges as BETA approaches 1."
  :args ((mass "Rest mass, kg")
         (beta "Speed as a fraction of c, |beta| < 1"))
  :returns "Kinetic energy, J"
  :examples (("relke(1, 0.9)" . "1.16313061027e17")
             ("relke(1, 1e-6)" . "44937.7589369"))
  ;; (gamma - 1) is computed as b^2 / (sqrt(1-b^2) (1 + sqrt(1-b^2))), which
  ;; is algebraically identical but cancellation-free.  Subtracting 1 from
  ;; gamma directly is catastrophic at everyday speeds -- gamma differs from 1
  ;; only in the 13th digit at beta = 1e-6, so the difference underflows the
  ;; working precision and this returned exactly 0 instead of the classical
  ;; 44937.76 J.  In this form the beta^2 factor stays out front and the low
  ;; speed limit falls out as m c^2 b^2 / 2 = m v^2 / 2 exactly.
  (progn
    ('cmacs-calculator--check-beta beta)
    (let* ((root (sqrt (- 1 (^ beta 2)))))
      (/ (* mass (^ cmacs-calculator--c 2) (^ beta 2))
         (* root (+ 1 root))))))

(cmacs-calculator-defcalc reltotale (mass beta)
  :category relativity
  :title "Relativistic total energy"
  :doc "Total energy of MASS moving at BETA, gamma m c^2 -- rest energy plus
kinetic energy, so reltotale(m, b) equals massenergy(m) + relke(m, b)."
  :args ((mass "Rest mass, kg")
         (beta "Speed as a fraction of c, |beta| < 1"))
  :returns "Total energy, J"
  :examples (("reltotale(1, 0.9)" . "2.061885789e17"))
  (* (lorentz beta) mass (^ cmacs-calculator--c 2)))

(cmacs-calculator-defcalc massenergy (mass)
  :category relativity
  :title "Mass-energy equivalence"
  :doc "Rest energy of MASS, E = m c^2.  One kilogram is about 9e16 J, some
21 megatons of TNT."
  :args ((mass "Rest mass, kg"))
  :returns "Rest energy, J"
  :examples (("massenergy(1)" . "89875517873681764"))
  (* mass (^ cmacs-calculator--c 2)))

(cmacs-calculator-defcalc reldoppler (freq beta)
  :category relativity
  :title "Relativistic Doppler shift"
  :doc "Frequency observed from a source receding or approaching at BETA,
f sqrt((1 + beta) / (1 - beta)).  BETA is positive when the source
*approaches* (blueshift) and negative when it recedes (redshift).

Unlike `dopplersound', only the relative speed enters -- there is no medium
to move through, so there is no separate source and observer term."
  :args ((freq "Emitted frequency, Hz")
         (beta "Approach speed as a fraction of c, |beta| < 1;
negative when receding"))
  :returns "Observed frequency, Hz"
  :examples (("reldoppler(440, 0.5)" . "762.102355331")
             ("reldoppler(440, -0.5)" . "254.034118443"))
  (progn
    ('cmacs-calculator--check-beta beta)
    (* freq (sqrt (/ (+ 1 beta) (- 1 beta))))))


;;; General relativity

(cmacs-calculator-defcalc schwarzschild (mass)
  :category relativity
  :title "Schwarzschild radius"
  :doc "Radius at which MASS becomes a black hole, 2 G M / c^2 -- the event
horizon of a non-rotating body.  About 2954 m for the Sun and 8.9 mm for the
Earth."
  :args ((mass "Mass, kg"))
  :returns "Schwarzschild radius, m"
  :examples (("schwarzschild(1.989e30)" . "2954.12655505")
             ("schwarzschild(5.972e24)" . "8.86980582543e-3")) ; Earth
  (/ (* 2 cmacs-calculator--G mass) (^ cmacs-calculator--c 2)))

(defun cmacs-calculator--check-horizon (mass radius)
  "Reject RADIUS unless it lies outside the horizon of MASS.
Inside the Schwarzschild radius the metric coefficient goes negative and the
gravitational formulas return complex numbers, which are not answers."
  (let ((rs (cmacs-calculator--numeric
             (ignore-errors (calcFunc-schwarzschild mass))))
        (r (cmacs-calculator--numeric radius)))
    (when (and rs r (not (math-lessp rs r)))
      (math-reject-arg radius
                       "*Radius must lie outside the Schwarzschild radius"))))

(cmacs-calculator-defcalc gravtimedilation (mass radius)
  :category relativity
  :title "Gravitational time dilation"
  :doc "Rate of a clock at RADIUS from a body of MASS, relative to one
infinitely far away: sqrt(1 - rs/r), where rs is the Schwarzschild radius.
Always below 1 -- clocks deeper in a gravity well run slow -- and it falls to
zero at the horizon.  The effect is tiny for ordinary bodies: about
0.9999999993 at Earth's surface, which GPS still has to correct for.

Rejected for RADIUS at or inside the horizon.  See `schwarzschild'."
  :args ((mass "Mass of the gravitating body, kg")
         (radius "Distance from its centre, m; must exceed the horizon"))
  :returns "Clock rate as a fraction of the far-away rate, below 1"
  :examples (("gravtimedilation(5.972e24, 6.371e6)" . "0.999999999304"))
  (progn
    ('cmacs-calculator--check-horizon mass radius)
    (sqrt (- 1 (/ (schwarzschild mass) radius)))))

(cmacs-calculator-defcalc gravredshift (mass radius)
  :category relativity
  :title "Gravitational redshift"
  :doc "Redshift z of light escaping to infinity from RADIUS above a body of
MASS, 1/sqrt(1 - rs/r) - 1.  The reciprocal of `gravtimedilation', minus one:
light climbing out of a gravity well loses energy and reddens.  Diverges at
the horizon, where light cannot escape at all.

Rejected for RADIUS at or inside the horizon."
  :args ((mass "Mass of the gravitating body, kg")
         (radius "Emission radius from the centre, m; must exceed the horizon"))
  :returns "Redshift z, dimensionless"
  :examples (("gravredshift(5.972e24, 6.371e6)" . "6.96107819392e-10"))
  ;; Computed as x / (sqrt(1-x) (1 + sqrt(1-x))), which is algebraically
  ;; identical to 1/sqrt(1-x) - 1 but avoids catastrophic cancellation.  In a
  ;; weak field rs/r is tiny, so sqrt(1-x) sits a hair under 1 and the literal
  ;; subtraction throws away almost every significant digit: at Earth's
  ;; surface the direct form yields `7e-10' where this one gives all twelve.
  (progn
    ('cmacs-calculator--check-horizon mass radius)
    (let* ((x (/ (schwarzschild mass) radius))
           (root (sqrt (- 1 x))))
      (/ x (* root (+ 1 root))))))

(cmacs-calculator-defcalc twinage (earthtime beta)
  :category relativity
  :title "Twin paradox -- age difference"
  :doc "How much less the travelling twin ages than the stay-at-home twin
over EARTHTIME at speed BETA: t (1 - 1/gamma).  The traveller's own elapsed
time is EARTHTIME/gamma, so this is the difference between them.

There is no real paradox: the situation is not symmetric, because only the
traveller turns around and so changes inertial frame.  This assumes the
turnaround is brief against the trip."
  :args ((earthtime "Time elapsed for the stay-at-home twin, any time unit")
         (beta "Travel speed as a fraction of c, |beta| < 1"))
  :returns "Age difference, in the same unit as EARTHTIME"
  :examples (("twinage(10, 0.9)" . "5.64110105648")
             ("twinage(10, 1e-6)" . "5e-12"))
  ;; (1 - 1/gamma) is 1 - sqrt(1-b^2), rewritten as b^2 / (1 + sqrt(1-b^2))
  ;; to keep it cancellation-free at low speed -- see the note on `relke'.
  (progn
    ('cmacs-calculator--check-beta beta)
    (let* ((root (sqrt (- 1 (^ beta 2)))))
      (/ (* earthtime (^ beta 2)) (+ 1 root)))))

(provide 'cmacs-calculator-physics)
;;; cmacs-calculator-physics.el ends here
