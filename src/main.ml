open Js_of_ocaml

type patch_entry = {
  sha1 : string;
  title : string;
  revision : string;
  game_code : string;
  version : int;
  patch : string;
  output_sha1 : string;
  config_offset : int;
}

type input_kind = Original | Patched

let entries =
  [
    {
      sha1 = "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc";
      title = "Pokémon FireRed";
      revision = "English 1.0";
      game_code = "BPRE";
      version = 0;
      patch = "firered-1.0-service-npc.bps";
      output_sha1 = "67d4661224992f590ed56bd8ef31103b73df58e2";
      config_offset = 15407696;
    };
    {
      sha1 = "dd5945db9b930750cb39d00c84da8571feebf417";
      title = "Pokémon FireRed";
      revision = "English 1.1";
      game_code = "BPRE";
      version = 1;
      patch = "firered-1.1-service-npc.bps";
      output_sha1 = "87d6c8be21ff23d0ec73101a11a590dd2e8c66c4";
      config_offset = 15407696;
    };
    {
      sha1 = "574fa542ffebb14be69902d1d36f1ec0a4afd71e";
      title = "Pokémon LeafGreen";
      revision = "English 1.0";
      game_code = "BPGE";
      version = 0;
      patch = "leafgreen-1.0-service-npc.bps";
      output_sha1 = "d31f982ff357f2f7f07c65daf98f5ab1a4ab3c80";
      config_offset = 15408456;
    };
    {
      sha1 = "7862c67bdecbe21d1d69ce082ce34327e1c6ed5e";
      title = "Pokémon LeafGreen";
      revision = "English 1.1";
      game_code = "BPGE";
      version = 1;
      patch = "leafgreen-1.1-service-npc.bps";
      output_sha1 = "9b96bee09f3b4ca03f55e736c8560b36f7942c4b";
      config_offset = 15408456;
    };
  ]

let config_magic = 0x43504e53

let current_file : Js.Unsafe.any option ref = ref None

let current_entry : patch_entry option ref = ref None

let current_kind : input_kind option ref = ref None

let busy = ref false

let element id = Dom_html.getElementById id

let set_text id text =
  Js.Unsafe.set (element id) "textContent" (Js.string text)

let set_property id name value = Js.Unsafe.set (element id) name value

let get_string_property id name =
  Js.to_string (Js.Unsafe.coerce (Js.Unsafe.get (element id) name))

let get_bool_property id name =
  Js.to_bool (Js.Unsafe.coerce (Js.Unsafe.get (element id) name))

let set_status = set_text "status"

let update_button () =
  let disabled = !busy || Option.is_none !current_entry in
  set_property "patch-button" "disabled" (Js.bool disabled);
  set_text "patch-button"
    (if !busy then "Working…"
     else
       match !current_kind with
       | Some Patched -> "Update settings and download ROM"
       | _ -> "Patch and download ROM")

let set_busy value =
  busy := value;
  update_button ()

let fail_with message =
  set_status message;
  set_busy false

let protect on_error action =
  try action () with
  | Failure message -> on_error message
  | _ -> on_error "Patch failed."

let on_event id name action =
  let callback =
    Js.wrap_callback (fun _ ->
        action ();
        Js._true)
  in
  Js.Unsafe.set (element id) ("on" ^ name) callback

let buffer_of_array_buffer array_buffer =
  let typed = new%js Typed_array.uint8Array_fromBuffer array_buffer in
  Bigarray.array1_of_genarray (Typed_array.to_genarray typed)

let typed_of_buffer buffer =
  Typed_array.from_genarray Typed_array.Int8_unsigned
    (Bigarray.genarray_of_array1 buffer)

let file_array_buffer file on_success on_error =
  protect (fun _ -> on_error ()) (fun () ->
      let promise = Js.Unsafe.meth_call file "arrayBuffer" [||] in
      let success =
        Js.wrap_callback (fun value ->
            on_success (Js.Unsafe.coerce value))
      in
      let failure = Js.wrap_callback (fun _ -> on_error ()) in
      ignore
        (Js.Unsafe.meth_call promise "then"
           [| Js.Unsafe.inject success; Js.Unsafe.inject failure |]))

let fetch_array_buffer path on_success on_error =
  protect (fun _ -> on_error ()) (fun () ->
      let constructor = Js.Unsafe.get Js.Unsafe.global "XMLHttpRequest" in
      let request = Js.Unsafe.new_obj constructor [||] in
      let loaded =
        Js.wrap_callback (fun _ ->
            let status : int = Js.Unsafe.get request "status" in
            if status >= 200 && status < 300 then
              on_success
                (Js.Unsafe.coerce (Js.Unsafe.get request "response"))
            else on_error ())
      in
      let failed = Js.wrap_callback (fun _ -> on_error ()) in
      ignore
        (Js.Unsafe.meth_call request "open"
           [|
             Js.Unsafe.inject (Js.string "GET");
             Js.Unsafe.inject (Js.string path);
             Js.Unsafe.inject Js._true;
           |]);
      Js.Unsafe.set request "responseType" (Js.string "arraybuffer");
      Js.Unsafe.set request "onload" loaded;
      Js.Unsafe.set request "onerror" failed;
      ignore (Js.Unsafe.meth_call request "send" [||]))

let hex_of_array_buffer array_buffer =
  let typed = new%js Typed_array.uint8Array_fromBuffer array_buffer in
  let size : int = Js.Unsafe.get typed "length" in
  let result = Buffer.create (size * 2) in
  for index = 0 to size - 1 do
    Buffer.add_string result
      (Printf.sprintf "%02x" (Typed_array.unsafe_get typed index))
  done;
  Buffer.contents result

let sha1 buffer on_success on_error =
  protect (fun _ -> on_error ()) (fun () ->
      let crypto = Js.Unsafe.get Js.Unsafe.global "crypto" in
      let subtle = Js.Unsafe.get crypto "subtle" in
      let typed = typed_of_buffer buffer in
      let promise =
        Js.Unsafe.meth_call subtle "digest"
          [|
            Js.Unsafe.inject (Js.string "SHA-1");
            Js.Unsafe.inject typed;
          |]
      in
      let success =
        Js.wrap_callback (fun value ->
            on_success (hex_of_array_buffer (Js.Unsafe.coerce value)))
      in
      let failure = Js.wrap_callback (fun _ -> on_error ()) in
      ignore
        (Js.Unsafe.meth_call promise "then"
           [| Js.Unsafe.inject success; Js.Unsafe.inject failure |]))

let download buffer filename =
  let typed = typed_of_buffer buffer in
  let parts = Js.array [| Js.Unsafe.inject typed |] in
  let options =
    Js.Unsafe.obj
      [| ("type", Js.Unsafe.inject (Js.string "application/octet-stream")) |]
  in
  let blob =
    Js.Unsafe.new_obj (Js.Unsafe.get Js.Unsafe.global "Blob")
      [| Js.Unsafe.inject parts; Js.Unsafe.inject options |]
  in
  let url_api = Js.Unsafe.get Js.Unsafe.global "URL" in
  let url : Js.js_string Js.t =
    Js.Unsafe.coerce
      (Js.Unsafe.meth_call url_api "createObjectURL"
         [| Js.Unsafe.inject blob |])
  in
  let anchor = Dom_html.createA Dom_html.document in
  Js.Unsafe.set anchor "href" url;
  Js.Unsafe.set anchor "download" (Js.string filename);
  ignore (Js.Unsafe.meth_call anchor "click" [||]);
  ignore
    (Js.Unsafe.meth_call url_api "revokeObjectURL"
       [| Js.Unsafe.inject url |])

let read_u32_le buffer offset =
  Bps.get buffer offset
  lor (Bps.get buffer (offset + 1) lsl 8)
  lor (Bps.get buffer (offset + 2) lsl 16)
  lor (Bps.get buffer (offset + 3) lsl 24)

let write_u32_le buffer offset value =
  Bps.set buffer offset (value land 0xff);
  Bps.set buffer (offset + 1) ((value lsr 8) land 0xff);
  Bps.set buffer (offset + 2) ((value lsr 16) land 0xff);
  Bps.set buffer (offset + 3) ((value lsr 24) land 0xff)

let copy_buffer source =
  let output =
    Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout
      (Bps.length source)
  in
  Bigarray.Array1.blit source output;
  output

let header_code buffer =
  if Bps.length buffer <= 0xbc then None
  else
    Some
      ( String.init 4 (fun index -> Char.chr (Bps.get buffer (0xac + index))),
        Bps.get buffer 0xbc )

let find_patched_candidate buffer =
  match header_code buffer with
  | None -> None
  | Some (game_code, version) ->
      List.find_opt
        (fun entry ->
          entry.game_code = game_code
          && entry.version = version
          && entry.config_offset + 8 <= Bps.length buffer
          && read_u32_le buffer entry.config_offset = config_magic)
        entries

let verify_patched entry buffer on_success on_error =
  match find_patched_candidate buffer with
  | Some candidate when candidate = entry ->
      let normalised = copy_buffer buffer in
      write_u32_le normalised (entry.config_offset + 4) 0;
      sha1 normalised
        (fun digest ->
          if digest = entry.output_sha1 then on_success () else on_error ())
        on_error
  | _ -> on_error ()

let find_entry digest = List.find_opt (fun entry -> entry.sha1 = digest) entries

let selected_file () =
  let files = Js.Unsafe.get (element "rom") "files" in
  let file =
    Js.Unsafe.meth_call files "item" [| Js.Unsafe.inject 0 |]
  in
  let present : bool Js.t =
    Js.Unsafe.coerce
      (Js.Unsafe.fun_call (Js.Unsafe.get Js.Unsafe.global "Boolean")
         [| Js.Unsafe.inject file |])
  in
  if Js.to_bool present then Some file else None

let choose_file () =
  current_entry := None;
  current_kind := None;
  current_file := selected_file ();
  update_button ();
  match !current_file with
  | None -> set_status "Choose an original or patched ROM to begin."
  | Some file ->
      set_busy true;
      set_status "Checking ROM…";
      file_array_buffer file
        (fun array_buffer ->
          protect fail_with (fun () ->
              let source = buffer_of_array_buffer array_buffer in
              sha1 source
                (fun digest ->
                  match find_entry digest with
                  | Some entry ->
                      current_entry := Some entry;
                      current_kind := Some Original;
                      set_status
                        (Printf.sprintf "Recognised original: %s, %s."
                           entry.title entry.revision);
                      set_busy false
                  | None ->
                      match find_patched_candidate source with
                      | Some entry ->
                          verify_patched entry source
                            (fun () ->
                              current_entry := Some entry;
                              current_kind := Some Patched;
                              set_status
                                (Printf.sprintf
                                   "Recognised patched: %s, %s. Optional settings can be updated directly."
                                   entry.title entry.revision);
                              set_busy false)
                            (fun () ->
                              set_status
                                (Printf.sprintf
                                   "Unsupported ROM. SHA-1: %s" digest);
                              set_busy false)
                      | None ->
                          set_status
                            (Printf.sprintf "Unsupported ROM. SHA-1: %s"
                               digest);
                          set_busy false)
                (fun () -> fail_with "Could not identify ROM.")))
        (fun () -> fail_with "Could not read ROM.")

let configuration_flags () =
  (if get_bool_property "run-indoors" "checked" then 1 else 0)
  lor (if get_bool_property "reusable-tms" "checked" then 2 else 0)
  lor (if get_bool_property "fast-eggs" "checked" then 4 else 0)
  lor (if get_bool_property "instant-text" "checked" then 8 else 0)

let filename file =
  Js.to_string (Js.Unsafe.coerce (Js.Unsafe.get file "name"))

let configure_and_download file entry output message =
  protect fail_with (fun () ->
      if read_u32_le output entry.config_offset <> config_magic then
        failwith "The service configuration block was not found.";
      write_u32_le output (entry.config_offset + 4) (configuration_flags ());
      sha1 output
        (fun final_hash ->
          download output (filename file);
          set_status (message ^ final_hash);
          set_busy false)
        (fun () -> fail_with "Final output verification failed."))

let patch_rom () =
  match (!current_file, !current_entry, !current_kind) with
  | Some file, Some entry, Some Original ->
      set_busy true;
      set_status "Applying and verifying patch…";
      file_array_buffer file
        (fun source_array_buffer ->
          fetch_array_buffer ("patches/" ^ entry.patch)
            (fun patch_array_buffer ->
              protect fail_with (fun () ->
                  let source = buffer_of_array_buffer source_array_buffer in
                  let patch = buffer_of_array_buffer patch_array_buffer in
                  let output = Bps.apply source patch in
                  sha1 output
                    (fun base_hash ->
                      protect fail_with (fun () ->
                          if base_hash <> entry.output_sha1 then
                            failwith
                              "Output verification failed; no file was saved.";
                          configure_and_download file entry output
                            "Done. Patched ROM downloaded with its original filename. Final SHA-1: "))
                    (fun () ->
                      fail_with "Output verification failed; no file was saved.")))
            (fun () -> fail_with "Patch file is unavailable."))
        (fun () -> fail_with "Could not read ROM.")
  | Some file, Some entry, Some Patched ->
      set_busy true;
      set_status "Verifying and updating patched ROM…";
      file_array_buffer file
        (fun array_buffer ->
          protect fail_with (fun () ->
              let output = buffer_of_array_buffer array_buffer in
              verify_patched entry output
                (fun () ->
                  configure_and_download file entry output
                    "Done. Patched ROM settings updated without reapplying BPS. Final SHA-1: ")
                (fun () ->
                  fail_with
                    "Patched ROM verification failed; no file was saved.")))
        (fun () -> fail_with "Could not read ROM.")
  | _ -> ()

let update_hardware_note () =
  let note =
    match get_string_property "hardware" "value" with
    | "gba" ->
        "The output is a standard GBA ROM suitable for compatible flash cartridges, Game Boy Advance hardware, and Nintendo DS hardware."
    | "mgba" ->
        "The download keeps the original ROM filename and runs through current mGBA releases, where loading an external BIOS remains optional."
    | _ ->
        "The download is a standard GBA ROM prepared for GBARunner3 through TWiLight Menu++, while its original filename remains unchanged."
  in
  set_text "hardware-note" note

let () =
  on_event "rom" "change" choose_file;
  on_event "hardware" "change" update_hardware_note;
  on_event "patch-button" "click" patch_rom;
  update_hardware_note ();
  update_button ()
