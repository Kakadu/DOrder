let eval x = 0

let rec loop x = 
	if (Random.bool ()) then
		let x = eval x in
		let _ = assert (x = 0) in
		loop x
	else assert (x = 0)

let main () = 
	let x = 0 in
	loop x

let _ = main ()