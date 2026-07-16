use std::ffi::c_void;
use std::ptr;
use std::slice;
use std::sync::Mutex;

const KEY_FRAME_FLAG: i32 = 1;
const JNI_GET_DIRECT_BUFFER_ADDRESS_INDEX: usize = 230;
const JNI_GET_DIRECT_BUFFER_CAPACITY_INDEX: usize = 231;

#[derive(Clone, Copy, Default, Debug)]
struct SampleSlot {
    offset: usize,
    len: usize,
    presentation_time_us: i64,
    flags: i32,
}

#[derive(Debug)]
struct EncodedRollingBuffer {
    arena: Vec<u8>,
    slots: Vec<SampleSlot>,
    head: usize,
    count: usize,
    write_offset: usize,
    used_bytes: usize,
    window_us: i64,
}

impl EncodedRollingBuffer {
    fn new(window_us: i64, max_samples: usize, byte_capacity: usize) -> Option<Self> {
        if window_us <= 0 || max_samples == 0 || byte_capacity == 0 {
            return None;
        }
        Some(Self {
            arena: vec![0; byte_capacity],
            slots: vec![SampleSlot::default(); max_samples],
            head: 0,
            count: 0,
            write_offset: 0,
            used_bytes: 0,
            window_us,
        })
    }

    fn clear(&mut self) {
        self.head = 0;
        self.count = 0;
        self.write_offset = 0;
        self.used_bytes = 0;
    }

    fn push(&mut self, data: &[u8], presentation_time_us: i64, flags: i32) -> i32 {
        if data.is_empty() {
            return 0;
        }
        if data.len() > self.arena.len() {
            return -4;
        }
        if self
            .last_slot()
            .is_some_and(|last| presentation_time_us < last.presentation_time_us)
        {
            self.clear();
        }

        self.prune_to_keyframe_window(presentation_time_us);
        while self.count == self.slots.len()
            || self.arena.len().saturating_sub(self.used_bytes) < data.len()
        {
            if !self.remove_oldest() {
                break;
            }
        }
        if self.count == self.slots.len()
            || self.arena.len().saturating_sub(self.used_bytes) < data.len()
        {
            return -5;
        }

        let offset = self.write_offset;
        self.copy_into_arena(offset, data);
        let slot_index = (self.head + self.count) % self.slots.len();
        self.slots[slot_index] = SampleSlot {
            offset,
            len: data.len(),
            presentation_time_us,
            flags,
        };
        self.count += 1;
        self.used_bytes += data.len();
        self.write_offset = (offset + data.len()) % self.arena.len();
        0
    }

    fn metrics(&self) -> CaptureCoreStats {
        let first_pts_us = self
            .first_slot()
            .map_or(-1, |slot| slot.presentation_time_us);
        let last_pts_us = self
            .last_slot()
            .map_or(-1, |slot| slot.presentation_time_us);
        CaptureCoreStats {
            sample_count: self.count as u32,
            key_frame_count: (0..self.count)
                .filter(|index| {
                    self.slot_at(*index)
                        .is_some_and(|slot| slot.flags & KEY_FRAME_FLAG != 0)
                })
                .count() as u32,
            size_bytes: self.used_bytes as u64,
            duration_us: if first_pts_us >= 0 && last_pts_us >= first_pts_us {
                (last_pts_us - first_pts_us) as u64
            } else {
                0
            },
            first_pts_us,
            last_pts_us,
        }
    }

    fn snapshot_from_keyframe(&self) -> Option<CaptureSnapshot> {
        let keyframe_index = (0..self.count).find(|index| {
            self.slot_at(*index)
                .is_some_and(|slot| slot.flags & KEY_FRAME_FLAG != 0)
        })?;
        let sample_count = self.count - keyframe_index;
        let total_bytes = (keyframe_index..self.count)
            .filter_map(|index| self.slot_at(index))
            .map(|slot| slot.len)
            .sum();
        let mut data = Vec::with_capacity(total_bytes);
        let mut samples = Vec::with_capacity(sample_count);
        for index in keyframe_index..self.count {
            let slot = self.slot_at(index)?;
            let snapshot_offset = data.len();
            data.resize(snapshot_offset + slot.len, 0);
            self.copy_from_arena(slot, &mut data[snapshot_offset..]);
            samples.push(SnapshotSample {
                offset: snapshot_offset,
                len: slot.len,
                presentation_time_us: slot.presentation_time_us,
                flags: slot.flags,
            });
        }
        Some(CaptureSnapshot { data, samples })
    }

    fn prune_to_keyframe_window(&mut self, newest_pts_us: i64) {
        let cutoff = newest_pts_us.saturating_sub(self.window_us);
        let mut newest_keyframe_at_or_before_cutoff = 0usize;
        for index in 0..self.count {
            let Some(slot) = self.slot_at(index) else {
                break;
            };
            if slot.presentation_time_us > cutoff {
                break;
            }
            if slot.flags & KEY_FRAME_FLAG != 0 {
                newest_keyframe_at_or_before_cutoff = index;
            }
        }
        for _ in 0..newest_keyframe_at_or_before_cutoff {
            self.remove_oldest();
        }
    }

    fn remove_oldest(&mut self) -> bool {
        if self.count == 0 {
            return false;
        }
        let slot = self.slots[self.head];
        self.used_bytes = self.used_bytes.saturating_sub(slot.len);
        self.slots[self.head] = SampleSlot::default();
        self.head = (self.head + 1) % self.slots.len();
        self.count -= 1;
        if self.count == 0 {
            self.head = 0;
            self.write_offset = 0;
            self.used_bytes = 0;
        }
        true
    }

    fn first_slot(&self) -> Option<SampleSlot> {
        self.slot_at(0)
    }

    fn last_slot(&self) -> Option<SampleSlot> {
        self.count
            .checked_sub(1)
            .and_then(|index| self.slot_at(index))
    }

    fn slot_at(&self, logical_index: usize) -> Option<SampleSlot> {
        if logical_index >= self.count || self.slots.is_empty() {
            return None;
        }
        Some(self.slots[(self.head + logical_index) % self.slots.len()])
    }

    fn copy_into_arena(&mut self, offset: usize, source: &[u8]) {
        let first_len = source.len().min(self.arena.len() - offset);
        self.arena[offset..offset + first_len].copy_from_slice(&source[..first_len]);
        if first_len < source.len() {
            self.arena[..source.len() - first_len].copy_from_slice(&source[first_len..]);
        }
    }

    fn copy_from_arena(&self, slot: SampleSlot, destination: &mut [u8]) {
        let first_len = slot.len.min(self.arena.len() - slot.offset);
        destination[..first_len].copy_from_slice(&self.arena[slot.offset..slot.offset + first_len]);
        if first_len < slot.len {
            destination[first_len..slot.len].copy_from_slice(&self.arena[..slot.len - first_len]);
        }
    }
}

#[derive(Debug)]
struct CaptureCore {
    ring: Mutex<EncodedRollingBuffer>,
}

#[derive(Clone, Copy, Debug)]
struct SnapshotSample {
    offset: usize,
    len: usize,
    presentation_time_us: i64,
    flags: i32,
}

#[derive(Debug)]
struct CaptureSnapshot {
    data: Vec<u8>,
    samples: Vec<SnapshotSample>,
}

impl CaptureSnapshot {
    fn sample(&self, index: usize) -> Option<SnapshotSample> {
        self.samples.get(index).copied()
    }

    fn max_sample_size(&self) -> usize {
        self.samples
            .iter()
            .map(|sample| sample.len)
            .max()
            .unwrap_or(0)
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub struct CaptureCoreStats {
    pub sample_count: u32,
    pub key_frame_count: u32,
    pub size_bytes: u64,
    pub duration_us: u64,
    pub first_pts_us: i64,
    pub last_pts_us: i64,
}

fn core_from_handle(handle: u64) -> Option<&'static CaptureCore> {
    if handle == 0 {
        return None;
    }
    // SAFETY: handles are created from Box<CaptureCore> below and remain valid until destroy.
    unsafe { (handle as *const CaptureCore).as_ref() }
}

fn snapshot_from_handle(handle: u64) -> Option<&'static CaptureSnapshot> {
    if handle == 0 {
        return None;
    }
    // SAFETY: handles are created from Box<CaptureSnapshot> below and remain valid until destroy.
    unsafe { (handle as *const CaptureSnapshot).as_ref() }
}

#[no_mangle]
pub extern "C" fn capture_core_create(window_us: i64, max_samples: u32, byte_capacity: u64) -> u64 {
    let Ok(byte_capacity) = usize::try_from(byte_capacity) else {
        return 0;
    };
    let Some(ring) = EncodedRollingBuffer::new(window_us, max_samples as usize, byte_capacity)
    else {
        return 0;
    };
    Box::into_raw(Box::new(CaptureCore {
        ring: Mutex::new(ring),
    })) as u64
}

#[no_mangle]
pub extern "C" fn capture_core_destroy(handle: u64) {
    if handle == 0 {
        return;
    }
    // SAFETY: ownership is returned exactly once by the caller that owns this handle.
    unsafe {
        drop(Box::from_raw(handle as *mut CaptureCore));
    }
}

#[no_mangle]
pub extern "C" fn capture_core_clear(handle: u64) -> i32 {
    let Some(core) = core_from_handle(handle) else {
        return -1;
    };
    let Ok(mut ring) = core.ring.lock() else {
        return -2;
    };
    ring.clear();
    0
}

#[no_mangle]
/// Pushes one encoded sample into the fixed-capacity ring.
///
/// # Safety
///
/// `handle` must identify a live capture core created by `capture_core_create`, and
/// `data` must remain readable for `len` bytes for the duration of this call.
pub unsafe extern "C" fn capture_core_push(
    handle: u64,
    data: *const u8,
    len: usize,
    presentation_time_us: i64,
    flags: i32,
) -> i32 {
    let Some(core) = core_from_handle(handle) else {
        return -1;
    };
    if data.is_null() || len == 0 {
        return -3;
    }
    let Ok(mut ring) = core.ring.lock() else {
        return -2;
    };
    // SAFETY: the caller guarantees a readable region for the duration of this call.
    let sample = unsafe { slice::from_raw_parts(data, len) };
    ring.push(sample, presentation_time_us, flags)
}

#[no_mangle]
/// Copies the current ring metrics into caller-owned storage.
///
/// # Safety
///
/// `handle` must identify a live capture core created by `capture_core_create`, and
/// `output` must be valid writable storage for one `CaptureCoreStats` value.
pub unsafe extern "C" fn capture_core_stats(handle: u64, output: *mut CaptureCoreStats) -> i32 {
    let Some(core) = core_from_handle(handle) else {
        return -1;
    };
    if output.is_null() {
        return -3;
    }
    let Ok(ring) = core.ring.lock() else {
        return -2;
    };
    // SAFETY: the caller provides writable storage for one CaptureCoreStats value.
    unsafe { ptr::write(output, ring.metrics()) };
    0
}

#[no_mangle]
pub extern "C" fn capture_core_snapshot(handle: u64) -> u64 {
    let Some(core) = core_from_handle(handle) else {
        return 0;
    };
    let Ok(ring) = core.ring.lock() else {
        return 0;
    };
    let Some(snapshot) = ring.snapshot_from_keyframe() else {
        return 0;
    };
    Box::into_raw(Box::new(snapshot)) as u64
}

#[no_mangle]
pub extern "C" fn capture_core_snapshot_destroy(handle: u64) {
    if handle == 0 {
        return;
    }
    // SAFETY: ownership is returned exactly once by the caller that owns this handle.
    unsafe {
        drop(Box::from_raw(handle as *mut CaptureSnapshot));
    }
}

#[no_mangle]
pub extern "C" fn capture_core_snapshot_count(handle: u64) -> u32 {
    snapshot_from_handle(handle).map_or(0, |snapshot| snapshot.samples.len() as u32)
}

#[no_mangle]
pub extern "C" fn capture_core_snapshot_max_sample_size(handle: u64) -> u64 {
    snapshot_from_handle(handle).map_or(0, |snapshot| snapshot.max_sample_size() as u64)
}

#[no_mangle]
pub extern "C" fn capture_core_snapshot_sample_size(handle: u64, index: u32) -> u64 {
    snapshot_from_handle(handle)
        .and_then(|snapshot| snapshot.sample(index as usize))
        .map_or(0, |sample| sample.len as u64)
}

#[no_mangle]
pub extern "C" fn capture_core_snapshot_sample_pts(handle: u64, index: u32) -> i64 {
    snapshot_from_handle(handle)
        .and_then(|snapshot| snapshot.sample(index as usize))
        .map_or(-1, |sample| sample.presentation_time_us)
}

#[no_mangle]
pub extern "C" fn capture_core_snapshot_sample_flags(handle: u64, index: u32) -> i32 {
    snapshot_from_handle(handle)
        .and_then(|snapshot| snapshot.sample(index as usize))
        .map_or(0, |sample| sample.flags)
}

#[no_mangle]
/// Copies one encoded sample from an immutable snapshot into caller-owned storage.
///
/// # Safety
///
/// `handle` must identify a live snapshot created by `capture_core_snapshot`, and
/// `destination` must be writable for at least `destination_capacity` bytes.
pub unsafe extern "C" fn capture_core_snapshot_copy_sample(
    handle: u64,
    index: u32,
    destination: *mut u8,
    destination_capacity: usize,
) -> i64 {
    let Some(snapshot) = snapshot_from_handle(handle) else {
        return -1;
    };
    let Some(sample) = snapshot.sample(index as usize) else {
        return -2;
    };
    if destination.is_null() || destination_capacity < sample.len {
        return -3;
    }
    // SAFETY: both regions are valid, non-overlapping, and sized for this sample.
    unsafe {
        ptr::copy_nonoverlapping(
            snapshot.data.as_ptr().add(sample.offset),
            destination,
            sample.len,
        );
    }
    sample.len as i64
}

type JInt = i32;
type JLong = i64;
type JObject = *mut c_void;
type JClass = JObject;
type JNIEnv = *const *const c_void;
type GetDirectBufferAddress = unsafe extern "C" fn(*mut JNIEnv, JObject) -> *mut c_void;
type GetDirectBufferCapacity = unsafe extern "C" fn(*mut JNIEnv, JObject) -> JLong;

unsafe fn jni_function<T: Copy>(env: *mut JNIEnv, index: usize) -> Option<T> {
    if env.is_null() || (*env).is_null() {
        return None;
    }
    let table = *env;
    let function = *table.add(index);
    if function.is_null() {
        return None;
    }
    // SAFETY: JNI's function-table indices and signatures are stable across JNI versions.
    Some(std::mem::transmute_copy::<*const c_void, T>(&function))
}

unsafe fn direct_buffer_region(
    env: *mut JNIEnv,
    buffer: JObject,
    offset: JInt,
    len: JInt,
) -> Option<(*mut u8, usize)> {
    if buffer.is_null() || offset < 0 || len < 0 {
        return None;
    }
    let get_address: GetDirectBufferAddress =
        unsafe { jni_function(env, JNI_GET_DIRECT_BUFFER_ADDRESS_INDEX)? };
    let get_capacity: GetDirectBufferCapacity =
        unsafe { jni_function(env, JNI_GET_DIRECT_BUFFER_CAPACITY_INDEX)? };
    let address = unsafe { get_address(env, buffer) } as *mut u8;
    let capacity = unsafe { get_capacity(env, buffer) };
    let end = i64::from(offset).checked_add(i64::from(len))?;
    if address.is_null() || capacity < 0 || end > capacity {
        return None;
    }
    // SAFETY: the offset was checked against the direct buffer's reported capacity.
    Some((unsafe { address.add(offset as usize) }, len as usize))
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeCreate(
    _env: *mut JNIEnv,
    _class: JClass,
    window_us: JLong,
    max_samples: JInt,
    byte_capacity: JLong,
) -> JLong {
    if max_samples <= 0 || byte_capacity <= 0 {
        return 0;
    }
    capture_core_create(window_us, max_samples as u32, byte_capacity as u64) as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeDestroy(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
) {
    capture_core_destroy(handle as u64);
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeClear(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
) -> JInt {
    capture_core_clear(handle as u64)
}

#[no_mangle]
/// JNI entry point that pushes a region of a Java direct `ByteBuffer` into the ring.
///
/// # Safety
///
/// The VM must provide a valid `JNIEnv`, `buffer` must be a live direct buffer, and
/// `handle` must identify a live capture core for the duration of this call.
pub unsafe extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativePushDirect(
    env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
    buffer: JObject,
    offset: JInt,
    len: JInt,
    presentation_time_us: JLong,
    flags: JInt,
) -> JInt {
    let Some((address, length)) = (unsafe { direct_buffer_region(env, buffer, offset, len) })
    else {
        return -3;
    };
    unsafe { capture_core_push(handle as u64, address, length, presentation_time_us, flags) }
}

fn stat_for_handle(handle: JLong) -> Option<CaptureCoreStats> {
    let mut stats = CaptureCoreStats::default();
    let code = unsafe { capture_core_stats(handle as u64, &mut stats) };
    (code == 0).then_some(stats)
}

macro_rules! jni_stat {
    ($name:ident, $return_type:ty, $default:expr, $field:ident) => {
        #[no_mangle]
        pub extern "C" fn $name(_env: *mut JNIEnv, _class: JClass, handle: JLong) -> $return_type {
            stat_for_handle(handle).map_or($default, |stats| stats.$field as $return_type)
        }
    };
}

jni_stat!(
    Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSampleCount,
    JInt,
    0,
    sample_count
);
jni_stat!(
    Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeKeyFrameCount,
    JInt,
    0,
    key_frame_count
);
jni_stat!(
    Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSizeBytes,
    JLong,
    0,
    size_bytes
);
jni_stat!(
    Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeDurationUs,
    JLong,
    0,
    duration_us
);
jni_stat!(
    Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeFirstPtsUs,
    JLong,
    -1,
    first_pts_us
);
jni_stat!(
    Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeLastPtsUs,
    JLong,
    -1,
    last_pts_us
);

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshot(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
) -> JLong {
    capture_core_snapshot(handle as u64) as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshotDestroy(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
) {
    capture_core_snapshot_destroy(handle as u64);
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshotCount(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
) -> JInt {
    capture_core_snapshot_count(handle as u64) as JInt
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshotMaxSampleSize(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
) -> JLong {
    capture_core_snapshot_max_sample_size(handle as u64) as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshotSampleSize(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
    index: JInt,
) -> JLong {
    if index < 0 {
        return 0;
    }
    capture_core_snapshot_sample_size(handle as u64, index as u32) as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshotSamplePts(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
    index: JInt,
) -> JLong {
    if index < 0 {
        return -1;
    }
    capture_core_snapshot_sample_pts(handle as u64, index as u32)
}

#[no_mangle]
pub extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshotSampleFlags(
    _env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
    index: JInt,
) -> JInt {
    if index < 0 {
        return 0;
    }
    capture_core_snapshot_sample_flags(handle as u64, index as u32)
}

#[no_mangle]
/// JNI entry point that copies one snapshot sample into a Java direct `ByteBuffer`.
///
/// # Safety
///
/// The VM must provide a valid `JNIEnv`, `destination` must be a live direct buffer,
/// and `handle` must identify a live snapshot for the duration of this call.
pub unsafe extern "C" fn Java_com_lumiaiq_MotionCapture_RustEncodedRollingBuffer_nativeSnapshotCopySample(
    env: *mut JNIEnv,
    _class: JClass,
    handle: JLong,
    index: JInt,
    destination: JObject,
) -> JLong {
    if index < 0 {
        return -2;
    }
    let get_address: GetDirectBufferAddress =
        match unsafe { jni_function(env, JNI_GET_DIRECT_BUFFER_ADDRESS_INDEX) } {
            Some(function) => function,
            None => return -3,
        };
    let get_capacity: GetDirectBufferCapacity =
        match unsafe { jni_function(env, JNI_GET_DIRECT_BUFFER_CAPACITY_INDEX) } {
            Some(function) => function,
            None => return -3,
        };
    let address = unsafe { get_address(env, destination) } as *mut u8;
    let capacity = unsafe { get_capacity(env, destination) };
    if address.is_null() || capacity < 0 {
        return -3;
    }
    unsafe {
        capture_core_snapshot_copy_sample(handle as u64, index as u32, address, capacity as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(index: usize, size: usize) -> Vec<u8> {
        vec![(index % 251) as u8; size]
    }

    #[test]
    fn retains_keyframe_aligned_four_second_window() {
        let mut ring = EncodedRollingBuffer::new(4_000_000, 500, 2_000_000).unwrap();
        for index in 0..361 {
            let flags = if index % 60 == 0 { KEY_FRAME_FLAG } else { 0 };
            assert_eq!(
                ring.push(&frame(index, 100), index as i64 * 1_000_000 / 60, flags),
                0
            );
        }
        let metrics = ring.metrics();
        assert!((240..=242).contains(&metrics.sample_count));
        assert!((3_990_000..=4_000_000).contains(&metrics.duration_us));
        assert_eq!(metrics.size_bytes, u64::from(metrics.sample_count) * 100);
        assert!(metrics.key_frame_count >= 4);
    }

    #[test]
    fn push_reuses_preallocated_arena_and_metadata() {
        let mut ring = EncodedRollingBuffer::new(1_000_000, 8, 128).unwrap();
        let arena_ptr = ring.arena.as_ptr();
        let arena_capacity = ring.arena.capacity();
        let slots_ptr = ring.slots.as_ptr();
        let slots_capacity = ring.slots.capacity();
        for index in 0..100 {
            assert_eq!(
                ring.push(&frame(index, 17), index as i64 * 10_000, KEY_FRAME_FLAG),
                0
            );
        }
        assert_eq!(ring.arena.as_ptr(), arena_ptr);
        assert_eq!(ring.arena.capacity(), arena_capacity);
        assert_eq!(ring.slots.as_ptr(), slots_ptr);
        assert_eq!(ring.slots.capacity(), slots_capacity);
    }

    #[test]
    fn wrapped_samples_round_trip_through_keyframe_snapshot() {
        let mut ring = EncodedRollingBuffer::new(10_000_000, 6, 23).unwrap();
        for index in 0..7 {
            let flags = if index == 2 || index == 5 {
                KEY_FRAME_FLAG
            } else {
                0
            };
            assert_eq!(ring.push(&frame(index, 5), index as i64 * 1000, flags), 0);
        }
        let snapshot = ring.snapshot_from_keyframe().unwrap();
        assert_eq!(
            snapshot.samples.first().unwrap().flags & KEY_FRAME_FLAG,
            KEY_FRAME_FLAG
        );
        for sample in &snapshot.samples {
            let bytes = &snapshot.data[sample.offset..sample.offset + sample.len];
            assert!(bytes.windows(2).all(|window| window[0] == window[1]));
        }
    }

    #[test]
    fn c_abi_snapshot_copies_encoded_bytes() {
        let handle = capture_core_create(4_000_000, 16, 1024);
        assert_ne!(handle, 0);
        let bytes = [1u8, 2, 3, 4];
        assert_eq!(
            unsafe {
                capture_core_push(handle, bytes.as_ptr(), bytes.len(), 10_000, KEY_FRAME_FLAG)
            },
            0
        );
        let snapshot = capture_core_snapshot(handle);
        assert_ne!(snapshot, 0);
        let mut output = [0u8; 4];
        assert_eq!(
            unsafe {
                capture_core_snapshot_copy_sample(snapshot, 0, output.as_mut_ptr(), output.len())
            },
            4
        );
        assert_eq!(output, bytes);
        capture_core_snapshot_destroy(snapshot);
        capture_core_destroy(handle);
    }
}
