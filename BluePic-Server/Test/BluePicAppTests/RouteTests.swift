/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

import Foundation
import Kitura
import XCTest
import Dispatch
import HeliumLogger
import SwiftyJSON

@testable import BluePicApp

class RouteTests: XCTestCase {
  
  private let queue = DispatchQueue(label: "Kitura runloop", qos: .userInitiated, attributes: .concurrent)

  private let serverController = try? ServerController()

  static var allTests : [(String, (RouteTests) -> () throws -> Void)] {
      return [
          ("testPing", testPing),
          ("testGetTags", testGetTags),
          ("testGettingImages", testGettingImages),
          ("testGettingSingleImage", testGettingSingleImage),
          ("testGettingImagesByTag", testGettingImagesByTag),
          ("testPostingImage", testPostingImage),
          ("testGettingImagesForUser", testGettingImagesForUser),
          ("testGettingUsers", testGettingUsers),
          ("testGettingSingleUser", testGettingSingleUser)
      ]
  }
  
  func resetDatabase() {
    #if os(Linux)
    let task = Task()
    #else
    let task = Process()
    #endif
    
    let initialPath = #file
    let components = initialPath.characters.split(separator: "/").map(String.init)
    let notLastFour = components[0..<components.count - 4]
    let directoryPath = "/" + notLastFour.joined(separator: "/") + "/Cloud-Scripts"

    task.currentDirectoryPath = directoryPath
    task.launchPath = "/bin/sh"
    task.arguments = [directoryPath + "/populator.sh"]
    task.launch()
    task.waitUntilExit()
  }
  
  override func setUp() {
    super.setUp()
    
//    resetDatabase()
    
    HeliumLogger.use()
    
    Kitura.addHTTPServer(onPort: 8090, with: serverController!.router)
    
    queue.async {
      Kitura.start()
    }
    
  }
  
  override func tearDown() {
    Kitura.stop()
  }

  func testPing() {
    
    let pingExpectation = expectation(description: "Hit ping endpoint and get simple text response.")
    
    self.getAccessToken { accessToken in
      URLRequest(forTestWithMethod: "GET", route: "ping", authToken: accessToken)
        .sendForTesting { data in
              
          let pingResult = String(data: data, encoding: String.Encoding.utf8)!
          XCTAssertTrue(pingResult.contains("Hello World"))
          pingExpectation.fulfill()
      }
    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }

  func testGetTags() {
    
    let tagExpectation = expectation(description: "Get the top 10 image tags.")
    let expectedResult = ["mountain", "flower", "nature", "bridge", "building", "city", "cloudy sky", "garden", "lake", "person"]
    
    URLRequest(forTestWithMethod: "GET", route: "tags")
      .sendForTesting { data in
        let tags = JSON(data: data)
        for (index, pair) in tags["records"].arrayValue.enumerated() {
          XCTAssertEqual(pair["key"].stringValue, expectedResult[index])
        }
        tagExpectation.fulfill()
    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }
  
  // MARK: Image related tests

  func testGettingImages() {
    
    let imageExpectation = expectation(description: "Get all images.")
    
    URLRequest(forTestWithMethod: "GET", route: "images")
      .sendForTesting { data in
        
        let images = JSON(data: data)
        let records = images["records"].arrayValue
        XCTAssertEqual(records.count, 9)
        let firstImage = records.first!
        self.assertImage2010(image: firstImage)
        let lastImage = records.last!
        self.assertImage2001(image: lastImage)
        imageExpectation.fulfill()

    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }
  
  func testGettingSingleImage() {
    
    let imageExpectation = expectation(description: "Get an image with a specific image.")
    
    URLRequest(forTestWithMethod: "GET", route: "images/2010")
      .sendForTesting { data in
        
        let image = JSON(data: data)
        self.assertImage2010(image: image)
        imageExpectation.fulfill()
    }
    
    waitForExpectations(timeout: 10.0, handler: nil)
  }
  
  func testGettingImagesByTag() {
    
    let imageExpectation = expectation(description: "Get all images with a specific tag.")
    
    URLRequest(forTestWithMethod: "GET", route: "images?tag=mountain")
      .sendForTesting { data in
        
        let images = JSON(data: data)
        let records = images["records"].arrayValue
        XCTAssertEqual(records.count, 3)
        let image = records.first!
        self.assertImage2010(image: image)
        
        // No need to test contents of every image, mainly want to know we got the correct images.
        let imageIds = [2010, 2008, 2003]
        for (index, img) in records.enumerated() {
          XCTAssertEqual(img["_id"].intValue, imageIds[index])
        }
        imageExpectation.fulfill()
        
    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }
  
  func testPostingImage() {
    
    let imageExpectation = expectation(description: "Post an image with server.")
    
    self.getAccessToken { accessToken in
    
      // find image
      let fileName = "city.png"
      let initialPath = #file
      let components = initialPath.characters.split(separator: "/").map(String.init)
      let notLastFour = components[0..<components.count - 4]
      let directoryPath = "/" + notLastFour.joined(separator: "/") + "/Cloud-Scripts/Object-Storage/images/city.png"
      let imageURL = URL(fileURLWithPath: directoryPath)
      
      let imageDictionary = ["fileName": fileName, "caption" : "my caption", "width" : 250, "height" : 300, "location" : ["name" : "Austin, TX", "latitude" : 34.53, "longitude" : 84.5]] as [String : Any]
      let boundary = "Boundary-\(UUID().uuidString)"
      let mimeType = "image/png"
      
      do {
        let imageData = try Data(contentsOf: imageURL)
        let jsonData = try JSONSerialization.data(withJSONObject: imageDictionary, options: JSONSerialization.WritingOptions(rawValue: 0))
        let tempJsonString = String(data: jsonData, encoding: String.Encoding.utf8)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8090/images")!, cachePolicy: .reloadIgnoringCacheData, timeoutInterval: 10.0)
        request.timeoutInterval = 60
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        var body = Data()
        guard let jsonString = tempJsonString, let boundaryStart = "--\(boundary)\r\n".data(using: String.Encoding.utf8),
          let dispositionEncoding = "Content-Disposition:form-data; name=\"imageJson\"\r\n\r\n".data(using: String.Encoding.utf8),
          let jsonEncoding = "\(jsonString)\r\n".data(using: String.Encoding.utf8),
          let imageDispositionEncoding = "Content-Disposition:form-data; name=\"imageBinary\"; filename=\"\(fileName)\"\r\n".data(using: String.Encoding.utf8),
          let imageTypeEncoding = "Content-Type: \(mimeType)\r\n\r\n".data(using: String.Encoding.utf8),
          let imageEndEncoding = "\r\n".data(using: String.Encoding.utf8),
          let boundaryEnd = "--\(boundary)--\r\n".data(using: String.Encoding.utf8) else {
            XCTFail("Post New Image Error: Could not encode all values for multipart data")
            return
        }
        body.append(boundaryStart)
        body.append(dispositionEncoding)
        body.append(jsonEncoding)
        body.append(boundaryStart)
        body.append(imageDispositionEncoding)
        body.append(imageTypeEncoding)
        body.append(imageData)
        body.append(imageEndEncoding)
        body.append(boundaryEnd)
        request.httpBody = body

        print("executing request: \(request)")
        URLSession(configuration: .default).dataTask(with: request) { data, response, error in
          if let error = error {
            XCTFail("Image Post failed with error: \(error)")
          } else {
            print("Image saved with resp: \(response)")
  //              if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 404 {
  //                URLRequest(forTestWithMethod: "GET", route: "images/\(22)")
  //                  .sendForTesting { data in
  //                    
  //                    let image = JSON(data: data)
  //                    XCTAssertEqual(image["fileName"].stringValue, fileName)
  //                    XCTAssertEqual(image["caption"].stringValue, imageDictionary["caption"] as! String)
  //                    imageExpectation.fulfill()
  //                }
  //              } else {
  //                XCTFail("Bad response from ther server.")
  //              }
            
            imageExpectation.fulfill()
          }
        }.resume()
        
        
      } catch {
        XCTFail("Failed to convert image dictionary to binary data.")
      }
    }

    waitForExpectations(timeout: 18.0, handler: nil)
  }
  
  func testGettingImagesForUser() {
    
    let imageExpectation = expectation(description: "Gets all images posted by a specific user.")
    
    self.getAccessToken { accessToken in
      URLRequest(forTestWithMethod: "GET", route: "users/1001/images", authToken: accessToken)
        .sendForTesting { data in
          
          let images = JSON(data: data)
          let records = images["records"].arrayValue
          XCTAssertEqual(records.count, 4)
          
          let imageIds = [2010, 2007, 2004, 2001]
          for (index, img) in records.enumerated() {
            XCTAssertEqual(img["_id"].intValue, imageIds[index])
          }
          imageExpectation.fulfill()
      }
    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }
  
  // MARK: User related tests
  
  func testGettingUsers() {
    
    let userExpectation = expectation(description: "Gets all Users.")
    
    self.getAccessToken { accessToken in
      URLRequest(forTestWithMethod: "GET", route: "users", authToken: accessToken)
        .sendForTesting { data in
          
          let users = JSON(data: data)
          let records = users["records"].arrayValue
          XCTAssertEqual(records.count, 5)
          let userValues: [(String, String)] = [("anonymous", "Anonymous"), ("1003", "Kevin White"), ("1002", "Sharon den Adel"), ("1001", "Peter Adams"), ("1000", "John Smith")]
          for (index, user) in records.enumerated() {
            XCTAssertEqual(userValues[index].0, user["_id"].stringValue)
            XCTAssertEqual(userValues[index].1, user["name"].stringValue)
            XCTAssertEqual("user", user["type"].stringValue)
          }
          userExpectation.fulfill()
      }
    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }
  
  func testGettingSingleUser() {
    
    let userExpectation = expectation(description: "Gets a specific User.")
    
    self.getAccessToken { accessToken in
      URLRequest(forTestWithMethod: "GET", route: "users/1003", authToken: accessToken)
        .sendForTesting { data in

          let user = JSON(data: data)
          XCTAssertEqual(user["_id"].stringValue, "1003")
          XCTAssertEqual(user["name"].stringValue, "Kevin White")
          XCTAssertEqual("user", user["type"].stringValue)
          XCTAssertNotNil(user["_rev"].string)
          userExpectation.fulfill()
      }
    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }
  
  func testCreatingUser() {
    
    let userExpectation = expectation(description: "Creates a new User.")
    
    self.getAccessToken { accessToken in
      
      let json = ["_id": "3434", "name": "Tim Billings"]
      do {
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: JSONSerialization.WritingOptions(rawValue: 0))
        URLRequest(forTestWithMethod: "POST", route: "users", authToken: accessToken, body: jsonData)
          .sendForTesting { data in
            
            let user = JSON(data: data)
            print("result: \(user.debugDescription)")
            userExpectation.fulfill()
        }
      } catch {
        XCTFail("Faild to convert dictionary to JSON")
      }
    }
    waitForExpectations(timeout: 10.0, handler: nil)
  }

}

// Used for helper testing methods
extension RouteTests {
  
  func assertImage2010(image: JSON) {
    XCTAssertEqual(image["contentType"].stringValue, "image/png")
    XCTAssertEqual(image["fileName"].stringValue, "road.png")
    XCTAssertEqual(image["width"].intValue, 600)
    XCTAssertEqual(image["height"].intValue, 402)
    XCTAssertEqual(image["deviceId"].intValue, 3001)
    XCTAssertEqual(image["_id"].intValue, 2010)
    XCTAssertEqual(image["type"].stringValue, "image")
    XCTAssertEqual(image["uploadedTs"].stringValue, "2016-05-05T13:25:43")
    XCTAssertTrue(image["url"].stringValue.contains("1001/road.png"))
    XCTAssertEqual(image["caption"].stringValue, "Road")
    
    let user = image["user"]
    XCTAssertEqual(user["_id"].intValue, 1001)
    XCTAssertEqual(user["name"].stringValue, "Peter Adams")
    XCTAssertEqual(user["type"].stringValue, "user")
    
    let tags = image["tags"].arrayValue
    XCTAssertEqual(tags.first!["confidence"].intValue, 89)
    XCTAssertEqual(tags.first!["label"].stringValue, "road")
    XCTAssertEqual(tags.last!["confidence"].intValue, 50)
    XCTAssertEqual(tags.last!["label"].stringValue, "mountain")
    
    let location = image["location"]
    XCTAssertEqual(location["latitude"].stringValue, "34.53")
    XCTAssertEqual(location["longitude"].stringValue, "84.5")
    XCTAssertEqual(location["name"].stringValue, "Austin, Texas")
    XCTAssertEqual(location["weather"]["description"].stringValue, "Mostly Sunny")
    XCTAssertEqual(location["weather"]["iconId"].intValue, 27)
    XCTAssertEqual(location["weather"]["temperature"].intValue, 85)
  }
  
  func assertImage2001(image: JSON) {
    XCTAssertEqual(image["contentType"].stringValue, "image/png")
    XCTAssertEqual(image["fileName"].stringValue, "bridge.png")
    XCTAssertEqual(image["width"].intValue, 600)
    XCTAssertEqual(image["height"].intValue, 900)
    XCTAssertEqual(image["deviceId"].intValue, 3001)
    XCTAssertEqual(image["_id"].intValue, 2001)
    XCTAssertEqual(image["type"].stringValue, "image")
    XCTAssertEqual(image["uploadedTs"].stringValue, "2016-04-07T16:25:43")
    XCTAssertTrue(image["url"].stringValue.contains("1001/bridge.png"))
    XCTAssertEqual(image["caption"].stringValue, "Bridge")
    
    let user = image["user"]
    XCTAssertEqual(user["_id"].intValue, 1001)
    XCTAssertEqual(user["name"].stringValue, "Peter Adams")
    XCTAssertEqual(user["type"].stringValue, "user")
    
    let tags = image["tags"].arrayValue
    XCTAssertEqual(tags.first!["confidence"].intValue, 75)
    XCTAssertEqual(tags.first!["label"].stringValue, "bridge")
    XCTAssertEqual(tags[1]["confidence"].intValue, 60)
    XCTAssertEqual(tags[1]["label"].stringValue, "city")
    XCTAssertEqual(tags.last!["confidence"].intValue, 50)
    XCTAssertEqual(tags.last!["label"].stringValue, "building")
    
    let location = image["location"]
    XCTAssertEqual(location["latitude"].stringValue, "34.53")
    XCTAssertEqual(location["longitude"].stringValue, "84.5")
    XCTAssertEqual(location["name"].stringValue, "Boston, Massachusetts")
    XCTAssertEqual(location["weather"]["description"].stringValue, "Mostly Cloudy")
    XCTAssertEqual(location["weather"]["iconId"].intValue, 27)
    XCTAssertEqual(location["weather"]["temperature"].intValue, 70)
  }
  
  func getAccessToken(completionHandler: @escaping (_ accessToken: String) -> Void) {
    URLRequest(forTestWithMethod: "GET", route: "token")
      .sendForTesting { data in
        let tokenData = JSON(data: data)
        let accessToken = tokenData["access_token"].stringValue
        completionHandler(accessToken)
    }
  }
  
}

private extension URLRequest {
  
  init(forTestWithMethod method: String, route: String = "", message: String? = nil, authToken: String? = nil, body: Data? = nil) {
    self.init(url: URL(string: "http://127.0.0.1:8090/" + route)!)
    addValue("application/json", forHTTPHeaderField: "Content-Type")
    if let authToken = authToken {
        addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    httpMethod = method
    cachePolicy = .reloadIgnoringCacheData
    if let body = body {
      httpBody = body
    }
  }
  
  func sendForTesting(fn: @escaping (Data) -> Void ) {
    let dataTask = URLSession(configuration: .default).dataTask(with: self) {
      data, response, error in
      XCTAssertNil(error)
      XCTAssertNotNil(data)
      switch (response as? HTTPURLResponse)?.statusCode {
        case nil: XCTFail("bad response")
        case 200?: fn(data!)
        case let sc?: XCTFail("bad status \(sc)")
      }
    }
    dataTask.resume()
  }
}
