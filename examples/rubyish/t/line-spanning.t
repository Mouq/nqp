puts "1..5"

a=[10,
   20]

puts "#{a[1]? 'ok' : 'nok'} 1 - array spanning lines"


b = [30 # some comments
,
    40

]
puts "#{b[1]? 'ok' : 'nok'} 2 - array spanning lines"

h = {"a" => 10,
     "b"
 , 20
, "c" => 30
}
puts "#{h<c>? 'ok' : 'nok'} 3 - hash spanning lines"

def tricky(k,
   n)
    puts "#{k} #{n} - multi-line signatures and calls"
end

tricky(
      "ok",

      4

     )

puts \
  "ok 5 - \\ line continuation"
