let rec loopc i j k n = 
	if k < n then
		(if (Random.bool ()) then
			(assert(k>=j);
			assert(j>=i))
		else ();
		loopc i j (k+1) n)
	else ()
					

let rec loopb i j n = 
	if j < n then
		(loopc i j j n;
		loopb i (j+1) n)
	else ()

let rec loopa i n = 
	if i < n then
		(loopb i i n;
		loopa (i+1) n)
	else ()
	
		

let main n = 
	let i = 0 in
	loopa i n
	
let _ = main 2
let _ = main (-2)