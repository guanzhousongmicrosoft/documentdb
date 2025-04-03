mongosh localhost:10260 -u TestAdmin -p Admin100 --authenticationMechanism SCRAM-SHA-256 --tls --tlsAllowInvalidCertificates

use sample_mflix
 
db.movies.insertOne( { title: "The Favourite", genres: ["Drama", "History"], runtime: 121, rated: "R", year: 2018, directors: ["Yorgos Lanthimos"], cast: ["Olivia Colman", "Emma Stone", "Rachel Weisz"], type: "movie" })
 
db.movies.find()
 
db.movies.deleteMany({})
 