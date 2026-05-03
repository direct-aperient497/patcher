open Js_of_ocaml

type patch_entry = {
  sha1 : string;
  title : string;
  revision : string;
  patch : string;
  output_sha1 : string;
  config_offset : int;
}

let entries =
  [
    {
      sha1 = "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc";
      title = "Pokémon FireRed";
      revision = "English 1.0";
      patch = "firered-1.0-service-npc.bps";
      output_sha1 = "3663fcce80ef8a61da72bb28f30b69cc7e56bcc1";
      config_offset = 15406064;
    };
    {
      sha1 = "dd5945db9b930750cb39d00c84da8571feebf417";
      title = "Pokémon FireRed";
      revision = "English 1.1";
      patch = "firered-1.1-service-npc.bps";
      output_sha1 = "04416e3eaa81a6d6e1e7f9b4b450b4d9cfcfe8a8";
      config_offset = 15406064;
    };
    {
      sha1 = "574fa542ffebb14be69902d1d36f1ec0a4afd71e";
      title = "Pokémon LeafGreen";
      revision = "English 1.0";
      patch = "leafgreen-1.0-service-npc.bps";
      output_sha1 = "db701e801e6af9ecbda7a4ed8ce2ad45cb7aeaea";
      config_offset = 15406824;
    };
    {
      sha1 = "7862c67bdecbe21d1d69ce082ce34327e1c6ed5e";
      title = "Pokémon LeafGreen";
      revision = "English 1.1";
      patch = "leafgreen-1.1-service-npc.bps";
      output_sha1 = "73e1774aed6cfa77ee2bf73fdf0343c775c83828";
      config_offset = 15406824;
    };
  ]

let config_magic = 0x43504e53

let current_file : Js.Unsafe.any option ref = ref None

let current_entry : patch_entry option ref = ref None

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
    (if !busy then "Working…" else "Patch and download ROM")

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
  current_file := selected_file ();
  update_button ();
  match !current_file with
  | None -> set_status "Choose an original ROM to begin."
  | Some file ->
      set_busy true;
      set_status "Checking ROM…";
      file_array_buffer file
        (fun array_buffer ->
          protect fail_with (fun () ->
              let source = buffer_of_array_buffer array_buffer in
              sha1 source
                (fun digest ->
                  current_entry := find_entry digest;
                  (match !current_entry with
                  | Some entry ->
                      set_status
                        (Printf.sprintf "Recognised: %s, %s." entry.title
                           entry.revision)
                  | None ->
                      set_status
                        (Printf.sprintf "Unsupported ROM. SHA-1: %s" digest));
                  set_busy false)
                (fun () -> fail_with "Could not identify ROM.")))
        (fun () -> fail_with "Could not read ROM.")

let configuration_flags () =
  (if get_bool_property "run-indoors" "checked" then 1 else 0)
  lor (if get_bool_property "reusable-tms" "checked" then 2 else 0)
  lor (if get_bool_property "fast-eggs" "checked" then 4 else 0)
  lor (if get_bool_property "instant-text" "checked" then 8 else 0)

let patch_rom () =
  match (!current_file, !current_entry) with
  | Some file, Some entry ->
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
                          if
                            read_u32_le output entry.config_offset
                            <> config_magic
                          then
                            failwith
                              "The service configuration block was not found.";
                          write_u32_le output (entry.config_offset + 4)
                            (configuration_flags ());
                          sha1 output
                            (fun final_hash ->
                              let filename =
                                Js.to_string
                                  (Js.Unsafe.coerce
                                     (Js.Unsafe.get file "name"))
                              in
                              download output filename;
                              set_status
                                (Printf.sprintf
                                   "Done. Patched ROM downloaded with its original filename. Final SHA-1: %s"
                                   final_hash);
                              set_busy false)
                            (fun () ->
                              fail_with "Final output verification failed.")))
                    (fun () ->
                      fail_with "Output verification failed; no file was saved.")))
            (fun () -> fail_with "Patch file is unavailable."))
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
