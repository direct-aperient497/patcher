open Bigarray

let buffer values =
  let result = Array1.create int8_unsigned c_layout (List.length values) in
  List.iteri (Array1.unsafe_set result) values;
  result

let values data =
  List.init (Array1.dim data) (Array1.unsafe_get data)

let u32_le value =
  [
    Int32.to_int (Int32.logand value 0xffl);
    Int32.to_int (Int32.logand (Int32.shift_right_logical value 8) 0xffl);
    Int32.to_int (Int32.logand (Int32.shift_right_logical value 16) 0xffl);
    Int32.to_int (Int32.shift_right_logical value 24);
  ]

let patch source target_crc instructions =
  let prefix = buffer ([ 0x42; 0x50; 0x53; 0x31; 0x83; 0x83; 0x80 ] @ instructions) in
  let source_crc = Bps.crc32 source (Bps.length source) in
  let body =
    buffer (values prefix @ u32_le source_crc @ u32_le target_crc)
  in
  let patch_crc = Bps.crc32 body (Bps.length body) in
  buffer (values body @ u32_le patch_crc)

let expect_failure expected action =
  match action () with
  | _ -> failwith ("Expected failure: " ^ expected)
  | exception Failure actual when actual = expected -> ()
  | exception Failure actual ->
      failwith (Printf.sprintf "Expected %S but received %S" expected actual)

let assert_equal expected actual =
  if values expected <> values actual then failwith "Buffers differ."

let corrupt data offset =
  let result = buffer (values data) in
  Array1.unsafe_set result offset (Array1.unsafe_get result offset lxor 1);
  result

let replace_checksum data offset checksum =
  let result = buffer (values data) in
  List.iteri (fun index value -> Array1.unsafe_set result (offset + index) value)
    (u32_le checksum);
  result

let repair_patch_checksum data =
  let offset = Bps.length data - 4 in
  replace_checksum data offset (Bps.crc32 data offset)

let () =
  let source = buffer [ 0x61; 0x62; 0x63 ] in
  let source_crc = Bps.crc32 source (Bps.length source) in
  let valid = patch source source_crc [ 0x88 ] in
  assert_equal source (Bps.apply source valid);
  let footer = Bps.length valid - 12 in
  let invalid_patch_crc = corrupt valid (Bps.length valid - 1) in
  expect_failure "BPS patch checksum does not match." (fun () ->
      Bps.apply source invalid_patch_crc);
  let invalid_source_crc = repair_patch_checksum (corrupt valid footer) in
  expect_failure "BPS source checksum does not match." (fun () ->
      Bps.apply source invalid_source_crc);
  let invalid_target_crc = repair_patch_checksum (corrupt valid (footer + 4)) in
  expect_failure "BPS target checksum does not match." (fun () ->
      Bps.apply source invalid_target_crc);
  let trailing = patch source source_crc [ 0x88; 0x80 ] in
  expect_failure "BPS instruction stream contains trailing data." (fun () ->
      Bps.apply source trailing);
  let truncated_instruction = patch source source_crc [ 0x89 ] in
  expect_failure "BPS target read is truncated." (fun () ->
      Bps.apply source truncated_instruction)
