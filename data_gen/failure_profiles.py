"""
Failure-mode signature generators for AegisOEE synthetic data.
Each function takes a progress ratio t in [0,1] (0=degradation start, 1=failure)
and returns multipliers/offsets to apply to baseline telemetry.
Seed-safe: all randomness via the passed numpy RNG.
"""
import numpy as np
from dataclasses import dataclass
from typing import Optional


@dataclass
class TelemetryModifiers:
    vib_rms_mult: float = 1.0
    vib_kurtosis_add: float = 0.0
    temp_c_add: float = 0.0
    rpm_mult: float = 1.0
    rpm_jitter: float = 0.0
    load_pct_add: float = 0.0
    cycle_time_mult: float = 1.0
    reject_rate_add: float = 0.0
    quality_flag: str = "OK"
    is_down: bool = False
    micro_stop_prob: float = 0.0


def bearing_wear(t: float, rng: np.random.Generator,
                 vib_alert: float = 4.5, vib_danger: float = 7.1,
                 baseline_vib: float = 2.0) -> TelemetryModifiers:
    """
    BEARING_WEAR: vibration_rms ramps 3-7 days; kurtosis rises first third;
    temp follows only in final 20%.
    """
    alert_mult = vib_alert / baseline_vib
    danger_mult = vib_danger / baseline_vib
    vib_mult = 1.0 + t * (danger_mult - 1.0) * 1.15
    noise = rng.normal(0, 0.03 * (1 + t))
    vib_mult = max(0.8, vib_mult + noise)

    kurt_add = 0.0
    if t < 0.33:
        kurt_add = t / 0.33 * 3.0
    elif t < 0.66:
        kurt_add = 3.0 + (t - 0.33) / 0.33 * 1.0
    else:
        kurt_add = 4.0 + (t - 0.66) / 0.34 * 2.0
    kurt_add += rng.normal(0, 0.3)

    temp_add = 0.0
    if t > 0.80:
        temp_add = (t - 0.80) / 0.20 * 15.0 + rng.normal(0, 1.0)

    micro_stop = min(0.15, t * 0.20)
    cycle_mult = 1.0 + t * 0.3

    return TelemetryModifiers(
        vib_rms_mult=vib_mult,
        vib_kurtosis_add=kurt_add,
        temp_c_add=temp_add,
        cycle_time_mult=cycle_mult,
        micro_stop_prob=micro_stop,
        reject_rate_add=t * 0.05,
    )


def lubrication_loss(t: float, rng: np.random.Generator) -> TelemetryModifiers:
    """
    LUBRICATION_LOSS: temp and vibration rise together, correlated with load.
    """
    load_factor = 0.7 + 0.3 * rng.random()
    vib_mult = 1.0 + t * 1.8 * load_factor + rng.normal(0, 0.05)
    temp_add = t * 25.0 * load_factor + rng.normal(0, 1.5)
    reject_add = t * 0.08 if t > 0.5 else 0.0
    return TelemetryModifiers(
        vib_rms_mult=max(0.9, vib_mult),
        temp_c_add=max(0, temp_add),
        load_pct_add=t * 5.0,
        cycle_time_mult=1.0 + t * 0.2,
        reject_rate_add=reject_add,
        micro_stop_prob=t * 0.10,
    )


def cooling_restriction(t: float, rng: np.random.Generator) -> TelemetryModifiers:
    """
    COOLING_RESTRICTION: temp ramps alone; vibration stays baseline.
    Quality loss -> thermal shutdown.
    """
    temp_add = t * 35.0 + rng.normal(0, 2.0)
    reject_add = max(0, (t - 0.3) * 0.15)
    return TelemetryModifiers(
        vib_rms_mult=1.0 + rng.normal(0, 0.02),
        temp_c_add=max(0, temp_add),
        reject_rate_add=reject_add,
        cycle_time_mult=1.0 + t * 0.1,
        micro_stop_prob=max(0, (t - 0.7) * 0.25),
    )


def rpm_instability(t: float, rng: np.random.Generator) -> TelemetryModifiers:
    """
    RPM_INSTABILITY: rpm/cycle-time oscillation amplitude grows.
    """
    osc_amplitude = t * 0.25
    rpm_jitter = osc_amplitude * (0.5 + 0.5 * rng.random())
    cycle_jitter = 1.0 + rng.normal(0, t * 0.15)
    return TelemetryModifiers(
        rpm_mult=1.0 + rng.normal(0, osc_amplitude * 0.5),
        rpm_jitter=rpm_jitter,
        cycle_time_mult=max(0.8, cycle_jitter),
        micro_stop_prob=t * 0.12,
        reject_rate_add=t * 0.04,
    )


def sensor_fault(t: float, rng: np.random.Generator,
                 fault_type: Optional[str] = None) -> TelemetryModifiers:
    """
    SENSOR_FAULT: flatlines, impossible jumps, or NULL gaps.
    NOT a real failure — set quality_flag accordingly.
    """
    if fault_type is None:
        fault_type = rng.choice(["FLATLINE", "SPIKE", "GAP"])

    if fault_type == "FLATLINE":
        return TelemetryModifiers(
            vib_rms_mult=0.0,
            quality_flag="FLATLINE",
        )
    elif fault_type == "SPIKE":
        return TelemetryModifiers(
            vib_rms_mult=5.0 + rng.random() * 5.0,
            temp_c_add=50 + rng.random() * 30,
            quality_flag="SPIKE",
        )
    else:
        return TelemetryModifiers(quality_flag="GAP")


FAILURE_GENERATORS = {
    "BEARING_WEAR": bearing_wear,
    "LUBRICATION_LOSS": lubrication_loss,
    "COOLING_RESTRICTION": cooling_restriction,
    "RPM_INSTABILITY": rpm_instability,
    "SENSOR_FAULT": sensor_fault,
}

FAILURE_DURATIONS_DAYS = {
    "BEARING_WEAR": (3, 7),
    "LUBRICATION_LOSS": (2, 5),
    "COOLING_RESTRICTION": (3, 6),
    "RPM_INSTABILITY": (2, 4),
    "SENSOR_FAULT": (0.1, 0.5),
}
